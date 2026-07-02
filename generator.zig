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
//   source ──parse──▶ []Prim ──lower──▶ []Node ──emit──▶ Zig source
//
// `Prim` is the parsed program: runs of `+`/`-` and `>`/`<` are already merged
// (and cancelled) into net deltas, and loops carry an explicit body.
//
// `Node` is the *optimized* program. `lower` performs two transformations:
//   * offset folding: pointer moves inside a straight-line region are deferred,
//     and every operation is tagged with its offset from the region's start, so
//     `>>+<<` becomes a single `data[2] += 1` with no pointer traffic.
//   * loop recognition: `[-]`-style clears become `set`, and balanced copy /
//     multiply loops such as `[->++<]` become a `mul` (straight-line multiply
//     add), turning an O(cell value) loop into O(1).

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
/// `cell[offset] += factor * cell[0]`.
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
    /// multiply-add: for each target `cell[t.offset] +%= t.factor *% cell[0]`,
    /// then `cell[0] = 0`.
    mul: []const Target,
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

/// Try to replace a loop body with straight-line code.
///
/// A body qualifies when it is a balanced (net pointer move 0), side-effect-free
/// run of additions — no I/O, no nested loops. Given the net delta `d0` applied
/// to the control cell (offset 0):
///   * with no other cells touched and `d0` odd, the loop is a clear → `set 0`
///     (odd deltas are invertible mod 256, so the cell is guaranteed to reach 0);
///   * with `d0 == -1` and other cells touched, it is a copy/multiply loop → a
///     `mul` node.
/// Anything else is left as a real loop.
fn recognize(allocator: Allocator, body: []const Node) Allocator.Error!?[]Node {
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

    if (targets.items.len == 0) {
        if (@mod(d0, 2) == 1) {
            const result = try allocator.alloc(Node, 1);
            result[0] = .{ .set = .{ .offset = 0, .value = 0 } };
            return result;
        }
        return null;
    }

    // `d0 == 255` is -1 mod 256: the control cell decrements by one each pass,
    // so the loop runs exactly cell[0] times.
    if (d0 == 255) {
        const result = try allocator.alloc(Node, 1);
        result[0] = .{ .mul = try targets.toOwnedSlice(allocator) };
        return result;
    }
    return null;
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
            .mul => |targets| {
                try emitLine(allocator, out, indent, "{");
                try emitLine(allocator, out, indent + 1, "const n = ptr[0];");
                for (targets) |t| {
                    const cell = try cellExpr(allocator, t.offset);
                    try emitLine(allocator, out, indent + 1, try std.fmt.allocPrint(allocator, "{s} +%= {d} *% n;", .{ cell, t.factor }));
                }
                try emitLine(allocator, out, indent + 1, "ptr[0] = 0;");
                try emitLine(allocator, out, indent, "}");
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
    const nodes = try lower(allocator, prims);

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
    // Keep `ptr` live even when the program is empty (no operations reference it).
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
}

test "recognize multiply / copy loops" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Copy current cell into the next one.
    try testing.expectEqualDeep(@as([]const Node, &.{
        .{ .mul = &.{.{ .offset = 1, .factor = 1 }} },
    }), try lowerSource(a, "[->+<]"));

    // Multiply-add into two cells: cell[1] += 2*n, cell[2] += 3*n.
    try testing.expectEqualDeep(@as([]const Node, &.{
        .{ .mul = &.{ .{ .offset = 1, .factor = 2 }, .{ .offset = 2, .factor = 3 } } },
    }), try lowerSource(a, "[->++>+++<<]"));
}

test "unbalanced loops are not treated as multiply loops" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A scan loop `[<]` must stay a real loop with a trailing move in its body.
    try testing.expectEqualDeep(@as([]const Node, &.{
        .{ .loop = &.{.{ .move = -1 }} },
    }), try lowerSource(a, "[<]"));
}

test "helloworld exercises the multiply optimization" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const hello_world = @embedFile("helloworld.bf");
    const nodes = try lowerSource(a, hello_world);
    try testing.expect(containsMul(nodes));
}
