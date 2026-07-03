const std = @import("std");
const Array = std.ArrayList;
const Allocator = std.mem.Allocator;

// ============================================================================
// Configuration
// ============================================================================

/// Build-time knobs for the generated program. `cell_bits` selects the tape
/// element width (and therefore the modulus of all cell arithmetic).
pub const Config = struct {
    cell_bits: u16 = 8,
    tape_size: usize = std.math.maxInt(u16),
    stdout_buffer: usize = 64 * 1024,

    /// 2^cell_bits — the modulus every cell operation wraps around.
    pub fn modulus(self: Config) u64 {
        return @as(u64, 1) << @intCast(self.cell_bits);
    }

    pub fn cellType(self: Config) []const u8 {
        return switch (self.cell_bits) {
            8 => "u8",
            16 => "u16",
            32 => "u32",
            else => unreachable, // validated by the build script
        };
    }
};

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
    add: i64,
    move: isize,
    print: usize,
    read,
    loop: []const Prim,
};

/// One destination of a recognized multiply loop:
/// `cell[offset] += factor * <iteration count>`.
const Target = struct { offset: isize, factor: u32 };

/// An optimized operation. Offsets are relative to the current data pointer.
/// Cell constants are stored in a `u32` (wide enough for any supported cell
/// width) already reduced modulo the cell modulus.
const Node = union(enum) {
    /// `cell[offset] +%= value`
    add: struct { offset: isize, value: u32 },
    /// `cell[offset] = value`
    set: struct { offset: isize, value: u32 },
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
    /// `inv` is the modular inverse of the control cell's per-pass delta;
    /// `inv == modulus-1` is the common decrement-by-one case where `k == cell[0]`.
    mul: struct { inv: u32, targets: []const Target },
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
    fn readAddRun(self: *Parser) i64 {
        var net: i64 = 0;
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

fn lower(allocator: Allocator, prims: []const Prim, cfg: Config) Allocator.Error![]Node {
    const m: i64 = @intCast(cfg.modulus());
    var out: Array(Node) = .empty;
    // `cursor` is the offset of the "current cell" relative to the actual data
    // pointer. Pointer moves only adjust this bookkeeping value; a real `move`
    // is emitted lazily, right before a loop or at the end of the region.
    var cursor: isize = 0;

    for (prims) |prim| {
        switch (prim) {
            .add => |v| {
                const value: u32 = @intCast(@mod(v, m));
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
                const inner = try lower(allocator, body, cfg);
                if (try recognize(allocator, inner, cfg)) |replacement| {
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

/// Inverse of an odd value modulo 2^bits (exists for every odd value). Uses
/// Newton's iteration, which doubles the number of correct bits each step.
fn modInverse(a: u64, bits: u16) u64 {
    const mask: u64 = if (bits >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(bits)) - 1;
    var x: u64 = 1;
    var i: usize = 0;
    while (i < 6) : (i += 1) x = (x *% (2 -% (a *% x))) & mask; // 6 steps cover 64 bits
    return x & mask;
}

/// Try to replace a loop body with straight-line code.
///
///   * `[>]` / `[<]` (a lone ±1 move) → `scan`.
///   * a balanced, side-effect-free run of additions (no I/O, no nested loops)
///     whose control cell (offset 0) has an *odd* net delta:
///       - no other cells touched → `set 0` (a clear);
///       - other cells touched     → `mul` (a copy/multiply loop).
///     An odd delta is invertible modulo 2^cell_bits, so the loop is guaranteed
///     to reach 0 and its iteration count is a fixed function of the control cell.
///
/// Anything else is left as a real loop.
fn recognize(allocator: Allocator, body: []const Node, cfg: Config) Allocator.Error!?[]Node {
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

    const m: i64 = @intCast(cfg.modulus());

    // Accumulate the net delta per offset.
    var offsets: Array(isize) = .empty;
    var sums: Array(i64) = .empty;
    for (body) |node| {
        const off = node.add.offset;
        const val: i64 = node.add.value;
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

    var d0: i64 = 0;
    var targets: Array(Target) = .empty;
    for (offsets.items, sums.items) |off, sum| {
        const factor: u32 = @intCast(@mod(sum, m));
        if (off == 0) {
            d0 = @mod(sum, m);
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
        const inv: u32 = @intCast(modInverse(@intCast(d0), cfg.cell_bits));
        result[0] = .{ .mul = .{ .inv = inv, .targets = try targets.toOwnedSlice(allocator) } };
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
            .mul => |mnode| {
                try out.append(allocator, node);
                for (mnode.targets) |t| setRemove(&zeros, t.offset);
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

fn emit(allocator: Allocator, out: *Array(u8), nodes: []const Node, indent: usize, cfg: Config) Allocator.Error!void {
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
                // `.` outputs a byte; wider cells emit their low 8 bits.
                const value = if (cfg.cell_bits == 8)
                    cell
                else
                    try std.fmt.allocPrint(allocator, "@as(u8, @truncate({s}))", .{cell});
                try emitLine(allocator, out, indent, try std.fmt.allocPrint(allocator, "try write_cell(out, {s}, {d});", .{ value, p.count }));
            },
            .read => |offset| {
                const cell = try cellExpr(allocator, offset);
                try emitLine(allocator, out, indent, try std.fmt.allocPrint(allocator, "{s} = try read_cell(in);", .{cell}));
            },
            .loop => |body| {
                try emitLine(allocator, out, indent, "while (ptr[0] != 0) {");
                try emit(allocator, out, body, indent + 1, cfg);
                try emitLine(allocator, out, indent, "}");
            },
            .mul => |mnode| {
                // `k` is the loop's iteration count. For the decrement-by-one
                // case (inv == modulus-1) that is just the control cell's value.
                const count_expr = if (mnode.inv == cfg.modulus() - 1)
                    "ptr[0]"
                else
                    try std.fmt.allocPrint(allocator, "(0 -% ptr[0]) *% {d}", .{mnode.inv});
                try emitLine(allocator, out, indent, "{");
                try emitLine(allocator, out, indent + 1, try std.fmt.allocPrint(allocator, "const k = {s};", .{count_expr}));
                for (mnode.targets) |t| {
                    const cell = try cellExpr(allocator, t.offset);
                    try emitLine(allocator, out, indent + 1, try std.fmt.allocPrint(allocator, "{s} +%= {d} *% k;", .{ cell, t.factor }));
                }
                try emitLine(allocator, out, indent + 1, "ptr[0] = 0;");
                try emitLine(allocator, out, indent, "}");
            },
            .scan => |stride| {
                const dir = if (stride == 1) "scan_right" else "scan_left";
                try emitLine(allocator, out, indent, try std.fmt.allocPrint(allocator, "ptr = {s}(Cell, &data, ptr);", .{dir}));
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

pub fn generate(allocator: Allocator, buffer: []u8, out_buffer: *Array(u8), cfg: Config) !void {
    const base = @embedFile("base.zig");
    try out_buffer.appendSlice(allocator, base);
    try out_buffer.append(allocator, '\n');

    const prims = try parse(allocator, buffer);
    const nodes = try eliminateDeadCode(allocator, try lower(allocator, prims, cfg), true);

    try out_buffer.appendSlice(allocator, try std.fmt.allocPrint(allocator,
        \\pub fn main(init: std.process.Init) !void {{
        \\    const Cell = {s};
        \\    const io = init.io;
        \\
        \\    var stdout_buffer: [{d}]u8 = undefined;
        \\    var stdout_writer = std.Io.File.Writer.init(.stdout(), io, &stdout_buffer);
        \\    const out = &stdout_writer.interface;
        \\
    , .{ cfg.cellType(), cfg.stdout_buffer }));
    if (usesInput(nodes)) {
        try out_buffer.appendSlice(allocator,
            \\    var stdin_buffer: [4096]u8 = undefined;
            \\    var stdin_reader = std.Io.File.Reader.init(.stdin(), io, &stdin_buffer);
            \\    const in = &stdin_reader.interface;
            \\
        );
    }
    try out_buffer.appendSlice(allocator, try std.fmt.allocPrint(allocator,
        \\    var data: [{d}]Cell = [1]Cell{{0}} ** {d};
        \\    var ptr: [*]Cell = &data;
        \\
        \\    // program starts
        \\
    , .{ cfg.tape_size, cfg.tape_size }));
    // Keep `ptr`/`data` live even when the program is empty.
    if (nodes.len == 0) try out_buffer.appendSlice(allocator, "    _ = &ptr;\n");

    try emit(allocator, out_buffer, nodes, 1, cfg);

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
const default_config = Config{};

fn parseSource(allocator: Allocator, src: []const u8) ![]const Prim {
    return parse(allocator, src);
}

fn lowerSource(allocator: Allocator, src: []const u8) ![]Node {
    return lower(allocator, try parse(allocator, src), default_config);
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

    // Generalized: control cell decremented by 3 -> inv(253) mod 256 == 85.
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

test "modular inverse for wider cells" {
    // inv(3) mod 2^16 == 43691; 3*43691 == 131073 == 2*65536 + 1.
    try testing.expectEqual(@as(u64, 43691), modInverse(3, 16));
    // A 16-bit `[--->+<]` decrements by 3, so its control delta is -3 mod 2^16
    // (== 65533) and the stored inverse is inv(65533) == 21845.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = try lower(a, try parse(a, "[--->+<]"), .{ .cell_bits = 16 });
    try testing.expectEqualDeep(@as([]const Node, &.{
        .{ .mul = .{ .inv = 21845, .targets = &.{.{ .offset = 1, .factor = 1 }} } },
    }), nodes);
}

test "helloworld exercises the multiply optimization" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const hello_world = @embedFile("helloworld.bf");
    const nodes = try optimizeSource(a, hello_world);
    try testing.expect(containsMul(nodes));
}

// ---------------------------------------------------------------------------
// Differential testing
//
// Two independent interpreters — one over the raw brainfuck source, one over
// the optimized `[]Node` IR — must produce the same output. This guards the
// whole optimizer (parse + lower + recognize + dce) against semantic drift.
// Both model an 8-bit tape (matching the default cell width) and give up
// (returning null, so the case is skipped) on out-of-bounds access or when a
// step/output budget is exceeded, so non-terminating programs never hang.
// ---------------------------------------------------------------------------

const interp_tape = 8192;
const interp_ptr0 = interp_tape / 2;
const interp_out_cap = 200_000;

/// Canonical interpretation of the raw source.
fn interpretSource(allocator: Allocator, src: []const u8, input: []const u8, limit: usize) !?[]u8 {
    const match = try allocator.alloc(usize, src.len);
    var stack: Array(usize) = .empty;
    for (src, 0..) |c, i| {
        if (c == '[') {
            try stack.append(allocator, i);
        } else if (c == ']') {
            const j = stack.pop() orelse return null; // unbalanced ] -> skip
            match[i] = j;
            match[j] = i;
        }
    }
    if (stack.items.len != 0) return null; // unbalanced [ -> skip

    var tape = [_]u8{0} ** interp_tape;
    var ptr: usize = interp_ptr0;
    var out: Array(u8) = .empty;
    var in_idx: usize = 0;
    var steps: usize = 0;
    var ip: usize = 0;
    while (ip < src.len) : (ip += 1) {
        steps += 1;
        if (steps > limit) return null;
        switch (src[ip]) {
            '>' => {
                if (ptr + 1 >= interp_tape) return null;
                ptr += 1;
            },
            '<' => {
                if (ptr == 0) return null;
                ptr -= 1;
            },
            '+' => tape[ptr] +%= 1,
            '-' => tape[ptr] -%= 1,
            '.' => {
                if (out.items.len >= interp_out_cap) return null;
                try out.append(allocator, tape[ptr]);
            },
            ',' => if (in_idx < input.len) {
                tape[ptr] = input[in_idx];
                in_idx += 1;
            },
            '[' => if (tape[ptr] == 0) {
                ip = match[ip];
            },
            ']' => if (tape[ptr] != 0) {
                ip = match[ip];
            },
            else => {},
        }
    }
    return out.items;
}

/// Interpretation of the optimized IR. Mirrors the code generator exactly.
const Machine = struct {
    tape: [interp_tape]u8 = [_]u8{0} ** interp_tape,
    ptr: usize = interp_ptr0,
    out: Array(u8) = .empty,
    input: []const u8,
    in_idx: usize = 0,
    steps: usize = 0,
    limit: usize,
    allocator: Allocator,

    const Fail = error{ Bounds, Limit, OutOfMemory };

    fn at(self: *Machine, offset: isize) Fail!usize {
        const idx = @as(isize, @intCast(self.ptr)) + offset;
        if (idx < 0 or idx >= interp_tape) return error.Bounds;
        return @intCast(idx);
    }

    fn move(self: *Machine, delta: isize) Fail!void {
        const p = @as(isize, @intCast(self.ptr)) + delta;
        if (p < 0 or p >= interp_tape) return error.Bounds;
        self.ptr = @intCast(p);
    }

    fn tick(self: *Machine) Fail!void {
        self.steps += 1;
        if (self.steps > self.limit) return error.Limit;
    }

    fn run(self: *Machine, nodes: []const Node) Fail!void {
        for (nodes) |node| {
            try self.tick();
            switch (node) {
                .add => |a| {
                    const i = try self.at(a.offset);
                    self.tape[i] +%= @intCast(a.value);
                },
                .set => |s| {
                    const i = try self.at(s.offset);
                    self.tape[i] = @intCast(s.value);
                },
                .move => |d| try self.move(d),
                .print => |p| {
                    const i = try self.at(p.offset);
                    var n = p.count;
                    while (n > 0) : (n -= 1) {
                        if (self.out.items.len >= interp_out_cap) return error.Limit;
                        try self.out.append(self.allocator, self.tape[i]);
                    }
                },
                .read => |off| {
                    const i = try self.at(off);
                    if (self.in_idx < self.input.len) {
                        self.tape[i] = self.input[self.in_idx];
                        self.in_idx += 1;
                    }
                },
                .loop => |body| while (self.tape[try self.at(0)] != 0) {
                    try self.tick();
                    try self.run(body);
                },
                .mul => |m| {
                    const si = try self.at(0);
                    const nval = self.tape[si];
                    const k: u8 = if (m.inv == 255) nval else (0 -% nval) *% @as(u8, @intCast(m.inv));
                    for (m.targets) |t| {
                        const ti = try self.at(t.offset);
                        self.tape[ti] +%= @as(u8, @intCast(t.factor)) *% k;
                    }
                    self.tape[si] = 0;
                },
                .scan => |stride| while (self.tape[self.ptr] != 0) {
                    try self.tick();
                    try self.move(stride);
                },
            }
        }
    }
};

fn interpretNodes(allocator: Allocator, nodes: []const Node, input: []const u8, limit: usize) !?[]u8 {
    var m = Machine{ .input = input, .limit = limit, .allocator = allocator };
    m.run(nodes) catch |err| switch (err) {
        error.Bounds, error.Limit => return null,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return m.out.items;
}

/// Assert the optimizer preserves observable behavior for one program.
fn diffTest(allocator: Allocator, src: []const u8, input: []const u8, limit: usize) !void {
    const reference = try interpretSource(allocator, src, input, limit);
    const nodes = try eliminateDeadCode(allocator, try lower(allocator, try parse(allocator, src), default_config), true);
    const optimized = try interpretNodes(allocator, nodes, input, limit);

    // Only compare when the reference finished within budget. A correct
    // optimizer never does *more* work, so if the reference finished the
    // optimized program must have finished too — and must match.
    if (reference) |r| {
        if (optimized) |o| {
            try testing.expectEqualSlices(u8, r, o);
        } else {
            std.debug.print("optimized program failed to reproduce source: \"{s}\"\n", .{src});
            return error.TestUnexpectedResult;
        }
    }
}

test "differential: curated programs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sierpinski = "++++++++[>+>++++<<-]>++>>+<[-[>>+<<-]+>>]>+[-<<<[->[+[-]+>++>>>-2<<]<[<]>>++++++[<<+++++>>-]+<<++.[-]<<]>.>+[>>]>+]";
    const cases = [_]struct { src: []const u8, in: []const u8 }{
        .{ .src = @embedFile("helloworld.bf"), .in = "" },
        .{ .src = sierpinski, .in = "" },
        .{ .src = "[-]", .in = "" }, // clear a zero cell
        .{ .src = "+++[-]", .in = "" }, // clear a set cell
        .{ .src = "+++[+]", .in = "" }, // clear via increment
        .{ .src = ">+>+<<", .in = "" }, // offset folding
        .{ .src = "[->+<]", .in = "" }, // multiply on a zero cell (no-op)
        .{ .src = "+++++[->++<]>.", .in = "" }, // copy/multiply then print
        .{ .src = "++++++[--->+++++++<]>.", .in = "" }, // generalized multiply
        .{ .src = "+++++++[>+++++++<-]>.", .in = "" }, // 49 -> '1'
        .{ .src = "++++++++[>++++++++<-]>[.-]", .in = "" }, // countdown print
        // known-zero DCE interactions: printing must not mark a cell zero, and a
        // clear before reuse must survive.
        .{ .src = "+++.[-]+.", .in = "" }, // print 3, clear, +1, print 1
        .{ .src = "+++.[-].", .in = "" }, // print 3, clear, print 0
        .{ .src = ">+++.[-]+.<", .in = "" }, // same at a nonzero offset
        .{ .src = "+++++[->++<]>.[-]<+[->++<]>.", .in = "" }, // mul, clear target, mul again
        .{ .src = "+>+>+>[<]<-.", .in = "" }, // left scan
        .{ .src = "+>+>+<<[>]>.", .in = "" }, // right scan
        .{ .src = ",.", .in = "A" }, // echo
        .{ .src = ",+.", .in = "A" }, // read, bump, print
        .{ .src = ",[.,]", .in = "Hi\x00" }, // cat until zero
        .{ .src = "+-+-><><", .in = "" }, // fully cancelling
        .{ .src = "", .in = "" }, // empty
        .{ .src = "comment only, no ops", .in = "" },
    };
    for (cases) |c| try diffTest(a, c.src, c.in, 100_000_000);
}

var fuzz_state: u64 = 0x9e3779b97f4a7c15;

fn nextRand() u64 {
    fuzz_state = fuzz_state *% 6364136223846793005 +% 1442695040888963407;
    return fuzz_state >> 33;
}

// Self-balanced snippets the optimizer recognizes (clears, copy/multiply loops,
// scans). Sprinkling them in makes the fuzzer exercise those rewrites — and
// their interaction with surrounding reuse — far more often than random
// bracket placement would.
const motifs = [_][]const u8{ "[-]", "[+]", "[->+<]", "[->++<]", "[--->+<]", "[>]", "[<]", "[->+>+<<]" };

fn randomProgram(allocator: Allocator) ![]u8 {
    var buf: Array(u8) = .empty;
    var depth: usize = 0;
    const len = 8 + (nextRand() % 40);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const r = nextRand() % 100;
        if (r < 12) {
            try buf.appendSlice(allocator, motifs[nextRand() % motifs.len]);
            continue;
        }
        const ch: u8 = if (r < 30) '+' else if (r < 48) '-' else if (r < 62) '>' else if (r < 76) '<' else if (r < 84) '.' else if (r < 90) ',' else if (r < 96) blk: {
            depth += 1;
            break :blk '[';
        } else if (depth > 0) blk: {
            depth -= 1;
            break :blk ']';
        } else '+';
        try buf.append(allocator, ch);
    }
    while (depth > 0) : (depth -= 1) try buf.append(allocator, ']');
    return buf.items;
}

test "differential: random programs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A modest per-program step budget keeps non-terminating programs cheap to
    // skip; the terminating majority still fuzzes the optimizer broadly.
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        const src = try randomProgram(a);
        try diffTest(a, src, "\x03\x01\x00", 300_000);
    }
}
