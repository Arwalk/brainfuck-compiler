const std = @import("std");
const Array = std.ArrayList;
const Allocator = std.mem.Allocator;

// ============================================================================
// Intermediate representation
// ============================================================================
//
// Compilation is split into passes rather than emitting text straight from the
// token stream:
//
//   source ─parse─▶ []Prim ─lower─▶ []Node ─dce─▶ []Node ─emit─▶ Zig source
//
// `Prim` is the parsed program: runs of `+`/`-` and `>`/`<` are already merged
// (and cancelled) into net deltas, and loops carry an explicit body.
//
// `Node` is the *optimized* program:
//   * lower  — offset folding (defer pointer moves, tag ops with an offset) and
//              loop recognition (clears, copy/multiply loops, pointer scans).
//   * dce    — dead-code elimination (drop redundant clears and trailing
//              effect-free work).

/// A parsed primitive. `+`/`-` runs are merged into a signed `add`, `>`/`<`
/// runs into a signed `move`, and `.` runs into a `print` count.
const Prim = union(enum) {
    add: i32,
    move: isize,
    print: usize,
    read,
    loop: []const Prim,
};

/// One destination of a recognized multiply loop:
/// `cell[offset] += factor * <iteration count>`.
const Target = struct { offset: isize, factor: u8 };

/// An optimized operation. Offsets are relative to the current data pointer.
const Node = union(enum) {
    /// `cell[offset] +%= value`
    add: struct { offset: isize, value: u8 },
    /// `cell[offset] = value`
    set: struct { offset: isize, value: u8 },
    /// `ptr += delta`
    move: isize,
    /// print `cell[offset]`, `count` times
    print: struct { offset: isize, count: usize },
    /// read one byte into `cell[offset]`
    read: isize,
    /// `while (cell[0] != 0) { body }`
    loop: []const Node,
    /// copy/multiply loop: with iteration count `k` derived from `cell[0]`,
    /// `cell[t.offset] +%= t.factor *% k` for each target, then `cell[0] = 0`.
    /// `inv` is the modular inverse (mod 256) of the control cell's per-pass
    /// delta; `inv == 255` is the common decrement-by-one case where `k == cell[0]`.
    mul: struct { inv: u8, targets: []const Target },
    /// pointer scan `[>]` / `[<]`: `while (cell[0] != 0) ptr += stride`, with
    /// `stride` either +1 or -1.
    scan: isize,
};

// ============================================================================
// Parsing: source text -> []Prim
// ============================================================================

const Parser = struct {
    buffer: []const u8,
    index: usize,
    allocator: Allocator,

    /// Sum a run of `+`/`-` into a net delta, skipping (and looking through)
    /// non-command characters, stopping at the next command.
    fn readAddRun(self: *Parser) i32 {
        var net: i32 = 0;
        while (self.index < self.buffer.len) : (self.index += 1) {
            switch (self.buffer[self.index]) {
                '+' => net += 1,
                '-' => net -= 1,
                '>', '<', '.', ',', '[', ']' => break,
                else => {},
            }
        }
        return net;
    }

    /// Sum a run of `>`/`<` into a net pointer delta.
    fn readMoveRun(self: *Parser) isize {
        var net: isize = 0;
        while (self.index < self.buffer.len) : (self.index += 1) {
            switch (self.buffer[self.index]) {
                '>' => net += 1,
                '<' => net -= 1,
                '+', '-', '.', ',', '[', ']' => break,
                else => {},
            }
        }
        return net;
    }

    /// Count a run of `.`.
    fn readPrintRun(self: *Parser) usize {
        var count: usize = 0;
        while (self.index < self.buffer.len) : (self.index += 1) {
            switch (self.buffer[self.index]) {
                '.' => count += 1,
                '>', '<', '+', '-', ',', '[', ']' => break,
                else => {},
            }
        }
        return count;
    }

    fn parseBlock(self: *Parser, top: bool) error{OutOfMemory}![]const Prim {
        var list: Array(Prim) = .empty;
        while (self.index < self.buffer.len) {
            switch (self.buffer[self.index]) {
                '+', '-' => {
                    const net = self.readAddRun();
                    if (net != 0) try list.append(self.allocator, .{ .add = net });
                },
                '>', '<' => {
                    const net = self.readMoveRun();
                    if (net != 0) try list.append(self.allocator, .{ .move = net });
                },
                '.' => try list.append(self.allocator, .{ .print = self.readPrintRun() }),
                ',' => {
                    self.index += 1;
                    try list.append(self.allocator, .{ .read = {} });
                },
                '[' => {
                    self.index += 1;
                    const body = try self.parseBlock(false);
                    try list.append(self.allocator, .{ .loop = body });
                },
                ']' => {
                    self.index += 1;
                    // A matching ']' closes this nested block; a stray one at the
                    // top level is ignored.
                    if (!top) break;
                },
                else => self.index += 1,
            }
        }
        return list.toOwnedSlice(self.allocator);
    }
};

fn parse(allocator: Allocator, buffer: []const u8) ![]const Prim {
    var parser = Parser{ .buffer = buffer, .index = 0, .allocator = allocator };
    return parser.parseBlock(true);
}

// ============================================================================
// Lowering: []Prim -> []Node  (offset folding + loop recognition)
// ============================================================================

fn lower(allocator: Allocator, prims: []const Prim) Allocator.Error![]Node {
    var out: Array(Node) = .empty;
    // `cursor` is the offset of the "current cell" relative to the actual data
    // pointer. Pointer moves only adjust this bookkeeping value; a real `move`
    // is emitted lazily, right before a loop or at the end of the region.
    var cursor: isize = 0;

    for (prims) |prim| {
        switch (prim) {
            .add => |v| {
                const value: u8 = @intCast(@mod(v, 256));
                if (value != 0) try out.append(allocator, .{ .add = .{ .offset = cursor, .value = value } });
            },
            .move => |d| cursor += d,
            .print => |count| try out.append(allocator, .{ .print = .{ .offset = cursor, .count = count } }),
            .read => try out.append(allocator, .{ .read = cursor }),
            .loop => |body| {
                // The pointer must physically sit on the control cell before a
                // loop, so flush any deferred move first.
                if (cursor != 0) {
                    try out.append(allocator, .{ .move = cursor });
                    cursor = 0;
                }
                const inner = try lower(allocator, body);
                if (try recognize(allocator, inner)) |replacement| {
                    try out.appendSlice(allocator, replacement);
                } else {
                    try out.append(allocator, .{ .loop = inner });
                }
            },
        }
    }

    if (cursor != 0) try out.append(allocator, .{ .move = cursor });
    return out.toOwnedSlice(allocator);
}

/// Inverse of an odd byte modulo 256 (exists for every odd value).
fn modInverse256(a: u8) u8 {
    var x: u16 = 1;
    while (x < 256) : (x += 1) {
        if ((@as(u16, a) *% x) & 0xff == 1) return @intCast(x);
    }
    unreachable; // only called with odd `a`
}

/// Try to replace a loop body with straight-line code.
///
///   * `[>]` / `[<]` (a lone ±1 move) → `scan`.
///   * a balanced, side-effect-free run of additions (no I/O, no nested loops)
///     whose control cell (offset 0) has an *odd* net delta:
///       - no other cells touched → `set 0` (a clear);
///       - other cells touched     → `mul` (a copy/multiply loop).
///     An odd delta is invertible mod 256, so the loop is guaranteed to reach 0
///     and its iteration count is a fixed function of the control cell.
///
/// Anything else is left as a real loop.
fn recognize(allocator: Allocator, body: []const Node) Allocator.Error!?[]Node {
    // Pointer scan: `while (cell[0] != 0) ptr += stride`.
    if (body.len == 1 and body[0] == .move) {
        const stride = body[0].move;
        if (stride == 1 or stride == -1) {
            const result = try allocator.alloc(Node, 1);
            result[0] = .{ .scan = stride };
            return result;
        }
        return null; // wider strides stay real loops
    }

    for (body) |node| {
        if (node != .add) return null; // I/O, moves (unbalanced), or nested loops
    }

    // Accumulate the net delta per offset.
    var offsets: Array(isize) = .empty;
    var sums: Array(i32) = .empty;
    for (body) |node| {
        const off = node.add.offset;
        const val: i32 = node.add.value;
        for (offsets.items, 0..) |existing, i| {
            if (existing == off) {
                sums.items[i] += val;
                break;
            }
        } else {
            try offsets.append(allocator, off);
            try sums.append(allocator, val);
        }
    }

    var d0: i32 = 0;
    var targets: Array(Target) = .empty;
    for (offsets.items, sums.items) |off, sum| {
        const factor: u8 = @intCast(@mod(sum, 256));
        if (off == 0) {
            d0 = @mod(sum, 256);
        } else if (factor != 0) {
            try targets.append(allocator, .{ .offset = off, .factor = factor });
        }
    }

    // An even control delta may never reach 0 (potential infinite loop), so it
    // is not a clear/multiply loop.
    if (d0 & 1 == 0) return null;

    const result = try allocator.alloc(Node, 1);
    if (targets.items.len == 0) {
        result[0] = .{ .set = .{ .offset = 0, .value = 0 } };
    } else {
        result[0] = .{ .mul = .{ .inv = modInverse256(@intCast(d0)), .targets = try targets.toOwnedSlice(allocator) } };
    }
    return result;
}

// ============================================================================
// Dead-code elimination: []Node -> []Node
// ============================================================================

fn setContains(items: []const isize, off: isize) bool {
    for (items) |o| if (o == off) return true;
    return false;
}

fn setRemove(list: *Array(isize), off: isize) void {
    var i: usize = 0;
    while (i < list.items.len) {
        if (list.items[i] == off) _ = list.swapRemove(i) else i += 1;
    }
}

fn setAdd(allocator: Allocator, list: *Array(isize), off: isize) !void {
    if (!setContains(list.items, off)) try list.append(allocator, off);
}

/// Remove work that cannot affect the program's output:
///   * a clear (`set 0`) of a cell already known to be zero — cells are known
///     zero after another clear, after a `mul`, and after any loop/scan (which
///     exit with the current cell == 0);
///   * at the top level, a trailing run of effect-free, always-terminating ops
///     (add/set/move/mul) after the final observable operation.
fn eliminateDeadCode(allocator: Allocator, nodes: []const Node, top: bool) Allocator.Error![]Node {
    var out: Array(Node) = .empty;
    var zeros: Array(isize) = .empty; // offsets currently known to hold zero

    for (nodes) |node| {
        switch (node) {
            .set => |s| {
                if (s.value == 0) {
                    if (setContains(zeros.items, s.offset)) continue; // redundant clear
                    try out.append(allocator, node);
                    try setAdd(allocator, &zeros, s.offset);
                } else {
                    try out.append(allocator, node);
                    setRemove(&zeros, s.offset);
                }
            },
            .add => |a| {
                try out.append(allocator, node);
                setRemove(&zeros, a.offset);
            },
            .read => |off| {
                try out.append(allocator, node);
                setRemove(&zeros, off);
            },
            .print => try out.append(allocator, node),
            .move => {
                try out.append(allocator, node);
                zeros.clearRetainingCapacity(); // frame shifted; known zeros no longer apply
            },
            .mul => |m| {
                try out.append(allocator, node);
                for (m.targets) |t| setRemove(&zeros, t.offset);
                try setAdd(allocator, &zeros, 0); // control cell cleared
            },
            .scan => {
                try out.append(allocator, node);
                zeros.clearRetainingCapacity();
                try setAdd(allocator, &zeros, 0); // scan exits on a zero cell
            },
            .loop => |body| {
                const cleaned = try eliminateDeadCode(allocator, body, false);
                try out.append(allocator, .{ .loop = cleaned });
                zeros.clearRetainingCapacity();
                try setAdd(allocator, &zeros, 0); // loop exits with cell[0] == 0
            },
        }
    }

    var result = try out.toOwnedSlice(allocator);
    if (top) {
        var end = result.len;
        while (end > 0) switch (result[end - 1]) {
            .add, .set, .move, .mul => end -= 1,
            else => break, // print/read are observable; loop/scan may not terminate
        };
        result = result[0..end];
    }
    return result;
}

// ============================================================================
// Code generation: []Node -> Zig source
// ============================================================================

/// A Zig lvalue for the cell at `offset` from the current pointer.
fn cellExpr(allocator: Allocator, offset: isize) ![]const u8 {
    if (offset == 0) return "ptr[0]";
    if (offset > 0) return std.fmt.allocPrint(allocator, "(ptr + {d})[0]", .{offset});
    return std.fmt.allocPrint(allocator, "(ptr - {d})[0]", .{-offset});
}

fn emitLine(allocator: Allocator, out: *Array(u8), indent: usize, text: []const u8) !void {
    var i: usize = 0;
    while (i < indent * 4) : (i += 1) try out.append(allocator, ' ');
    try out.appendSlice(allocator, text);
    try out.append(allocator, '\n');
}

fn emit(allocator: Allocator, out: *Array(u8), nodes: []const Node, indent: usize) Allocator.Error!void {
    for (nodes) |node| {
        switch (node) {
            .add => |a| {
                const cell = try cellExpr(allocator, a.offset);
                try emitLine(allocator, out, indent, try std.fmt.allocPrint(allocator, "{s} +%= {d};", .{ cell, a.value }));
            },
            .set => |s| {
                const cell = try cellExpr(allocator, s.offset);
                try emitLine(allocator, out, indent, try std.fmt.allocPrint(allocator, "{s} = {d};", .{ cell, s.value }));
            },
            .move => |d| {
                const text = if (d > 0)
                    try std.fmt.allocPrint(allocator, "ptr += {d};", .{d})
                else
                    try std.fmt.allocPrint(allocator, "ptr -= {d};", .{-d});
                try emitLine(allocator, out, indent, text);
            },
            .print => |p| {
                const cell = try cellExpr(allocator, p.offset);
                try emitLine(allocator, out, indent, try std.fmt.allocPrint(allocator, "try write_cell(out, {s}, {d});", .{ cell, p.count }));
            },
            .read => |offset| {
                const cell = try cellExpr(allocator, offset);
                try emitLine(allocator, out, indent, try std.fmt.allocPrint(allocator, "{s} = try read_cell(in);", .{cell}));
            },
            .loop => |body| {
                try emitLine(allocator, out, indent, "while (ptr[0] != 0) {");
                try emit(allocator, out, body, indent + 1);
                try emitLine(allocator, out, indent, "}");
            },
            .mul => |m| {
                // `k` is the loop's iteration count. For the decrement-by-one
                // case (inv == 255) that is just the control cell's value.
                const count_expr = if (m.inv == 255)
                    "ptr[0]"
                else
                    try std.fmt.allocPrint(allocator, "(0 -% ptr[0]) *% {d}", .{m.inv});
                try emitLine(allocator, out, indent, "{");
                try emitLine(allocator, out, indent + 1, try std.fmt.allocPrint(allocator, "const k = {s};", .{count_expr}));
                for (m.targets) |t| {
                    const cell = try cellExpr(allocator, t.offset);
                    try emitLine(allocator, out, indent + 1, try std.fmt.allocPrint(allocator, "{s} +%= {d} *% k;", .{ cell, t.factor }));
                }
                try emitLine(allocator, out, indent + 1, "ptr[0] = 0;");
                try emitLine(allocator, out, indent, "}");
            },
            .scan => |stride| {
                if (stride == 1)
                    try emitLine(allocator, out, indent, "ptr = scan_right(&data, ptr);")
                else
                    try emitLine(allocator, out, indent, "ptr = scan_left(&data, ptr);");
            },
        }
    }
}

fn usesInput(nodes: []const Node) bool {
    for (nodes) |node| switch (node) {
        .read => return true,
        .loop => |body| if (usesInput(body)) return true,
        else => {},
    };
    return false;
}

pub fn generate(allocator: Allocator, buffer: []u8, out_buffer: *Array(u8)) !void {
    const base = @embedFile("base.zig");
    try out_buffer.appendSlice(allocator, base);
    try out_buffer.append(allocator, '\n');

    const prims = try parse(allocator, buffer);
    const nodes = try eliminateDeadCode(allocator, try lower(allocator, prims), true);

    try out_buffer.appendSlice(allocator,
        \\pub fn main(init: std.process.Init) !void {
        \\    const io = init.io;
        \\
        \\    var stdout_buffer: [4096]u8 = undefined;
        \\    var stdout_writer = std.Io.File.Writer.init(.stdout(), io, &stdout_buffer);
        \\    const out = &stdout_writer.interface;
        \\
    );
    if (usesInput(nodes)) {
        try out_buffer.appendSlice(allocator,
            \\    var stdin_buffer: [4096]u8 = undefined;
            \\    var stdin_reader = std.Io.File.Reader.init(.stdin(), io, &stdin_buffer);
            \\    const in = &stdin_reader.interface;
            \\
        );
    }
    try out_buffer.appendSlice(allocator,
        \\    var data: [std.math.maxInt(u16)]u8 = [1]u8{0} ** std.math.maxInt(u16);
        \\    var ptr: [*]u8 = &data;
        \\
        \\    // program starts
        \\
    );
    // Keep `ptr`/`data` live even when the program is empty.
    if (nodes.len == 0) try out_buffer.appendSlice(allocator, "    _ = &ptr;\n");

    try emit(allocator, out_buffer, nodes, 1);

    try out_buffer.appendSlice(allocator,
        \\
        \\    // program ends
        \\    try out.flush();
        \\}
        \\
    );
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn parseSource(allocator: Allocator, src: []const u8) ![]const Prim {
    return parse(allocator, src);
}

fn lowerSource(allocator: Allocator, src: []const u8) ![]Node {
    return lower(allocator, try parse(allocator, src));
}

fn optimizeSource(allocator: Allocator, src: []const u8) ![]Node {
    return eliminateDeadCode(allocator, try lowerSource(allocator, src), true);
}

fn containsMul(nodes: []const Node) bool {
    for (nodes) |node| switch (node) {
        .mul => return true,
        .loop => |body| if (containsMul(body)) return true,
        else => {},
    };
    return false;
}

test "parse merges runs and cancels" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualDeep(@as([]const Prim, &.{.{ .add = 3 }}), try parseSource(a, "+++"));
    try testing.expectEqualDeep(@as([]const Prim, &.{.{ .add = 5 }}), try parseSource(a, "++ comment +++"));
    try testing.expectEqual(@as(usize, 0), (try parseSource(a, "+-")).len); // cancels
    try testing.expectEqualDeep(@as([]const Prim, &.{.{ .move = 1 }}), try parseSource(a, ">><"));
    try testing.expectEqualDeep(@as([]const Prim, &.{.{ .print = 2 }}), try parseSource(a, ".."));
}

test "lower folds pointer moves into offsets" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // ">+>+<<" nets to no pointer movement, so both adds become offset writes.
    try testing.expectEqualDeep(@as([]const Node, &.{
        .{ .add = .{ .offset = 1, .value = 1 } },
        .{ .add = .{ .offset = 2, .value = 1 } },
    }), try lowerSource(a, ">+>+<<"));

    // An unbalanced region keeps a single trailing move.
    try testing.expectEqualDeep(@as([]const Node, &.{
        .{ .add = .{ .offset = 1, .value = 1 } },
        .{ .move = 1 },
    }), try lowerSource(a, ">+"));
}

test "recognize clear loops" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const expected = @as([]const Node, &.{.{ .set = .{ .offset = 0, .value = 0 } }});
    try testing.expectEqualDeep(expected, try lowerSource(a, "[-]"));
    try testing.expectEqualDeep(expected, try lowerSource(a, "[+]"));
    try testing.expectEqualDeep(expected, try lowerSource(a, "[--- ]")); // odd delta still clears
    // even delta is not a guaranteed clear -> stays a loop
    try testing.expect(std.meta.activeTag((try lowerSource(a, "[--]"))[0]) == .loop);
}

test "recognize multiply / copy loops" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Copy current cell into the next one (decrement-by-one -> inv 255).
    try testing.expectEqualDeep(@as([]const Node, &.{
        .{ .mul = .{ .inv = 255, .targets = &.{.{ .offset = 1, .factor = 1 }} } },
    }), try lowerSource(a, "[->+<]"));

    // Multiply-add into two cells.
    try testing.expectEqualDeep(@as([]const Node, &.{
        .{ .mul = .{ .inv = 255, .targets = &.{ .{ .offset = 1, .factor = 2 }, .{ .offset = 2, .factor = 3 } } } },
    }), try lowerSource(a, "[->++>+++<<]"));

    // Generalized: control cell decremented by 3 -> inverse of 3 mod 256 is 171,
    // and inv(253) == 85.
    try testing.expectEqualDeep(@as([]const Node, &.{
        .{ .mul = .{ .inv = 85, .targets = &.{.{ .offset = 1, .factor = 1 }} } },
    }), try lowerSource(a, "[--->+<]"));
}

test "recognize pointer scans" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualDeep(@as([]const Node, &.{.{ .scan = 1 }}), try lowerSource(a, "[>]"));
    try testing.expectEqualDeep(@as([]const Node, &.{.{ .scan = -1 }}), try lowerSource(a, "[<]"));
    // Wider strides are not vectorizable scans; keep them as real loops.
    try testing.expect(std.meta.activeTag((try lowerSource(a, "[>>]"))[0]) == .loop);
}

test "dead code elimination drops redundant clears" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The second clear of the same cell (print doesn't touch it) is redundant.
    try testing.expectEqualDeep(@as([]const Node, &.{
        .{ .set = .{ .offset = 0, .value = 0 } },
        .{ .print = .{ .offset = 0, .count = 1 } },
    }), try optimizeSource(a, "[-].[-]"));

    // A multiply loop already zeroes the control cell, so a following clear goes.
    try testing.expectEqualDeep(@as([]const Node, &.{
        .{ .mul = .{ .inv = 255, .targets = &.{.{ .offset = 1, .factor = 1 }} } },
        .{ .print = .{ .offset = 0, .count = 1 } },
    }), try optimizeSource(a, "[->+<][-]."));
}

test "dead code elimination trims trailing effect-free work" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Everything after the last print is unobservable.
    try testing.expectEqualDeep(@as([]const Node, &.{
        .{ .print = .{ .offset = 0, .count = 1 } },
    }), try optimizeSource(a, ".>+++<--"));

    // A program with no output at all optimizes away entirely.
    try testing.expectEqual(@as(usize, 0), (try optimizeSource(a, "+++>++[-]<")).len);
}

test "helloworld exercises the multiply optimization" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const hello_world = @embedFile("helloworld.bf");
    const nodes = try optimizeSource(a, hello_world);
    try testing.expect(containsMul(nodes));
}
