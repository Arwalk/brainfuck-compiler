const std = @import("std");
const Array = std.ArrayList;

fn add_indent(out_buffer: anytype, allocator: std.mem.Allocator, indent: usize) !void {
    var i: usize = 0;
    while (i < indent) : (i += 1) {
        try out_buffer.append(allocator, ' ');
    }
}

const BfOpEnum = enum { push, pop, inc, dec, print, input, open_while, close_while, clear, noop };

const BfOp = union(BfOpEnum) {
    push: usize,
    pop: usize,
    inc: usize,
    dec: usize,
    print: usize,
    input,
    open_while,
    close_while,
    clear,
    noop,
};

const Tokenizer = struct {
    buffer: []const u8,
    index: usize,

    pub fn init(buffer: []const u8) Tokenizer {
        return .{ .buffer = buffer, .index = 0 };
    }

    fn count_same(self: *Tokenizer, char: u8) usize {
        var count: usize = 0;
        while (self.index < self.buffer.len) : (self.index += 1) {
            const current_char = self.buffer[self.index];
            if (current_char == char) {
                count += 1;
            } else {
                switch (current_char) {
                    '>', '<', '+', '-', '.', ',', '[', ']' => break,
                    else => continue,
                }
            }
        }
        return count;
    }

    pub fn next(self: *Tokenizer) ?BfOp {
        if (self.index >= self.buffer.len) {
            return null;
        }

        const current_char = self.buffer[self.index];

        switch (current_char) {
            '>' => return BfOp{ .push = self.count_same(current_char) },
            '<' => return BfOp{ .pop = self.count_same(current_char) },
            '+' => return BfOp{ .inc = self.count_same(current_char) },
            '-' => return BfOp{ .dec = self.count_same(current_char) },
            '.' => return BfOp{ .print = self.count_same(current_char) },
            ',' => {
                self.index += 1;
                return BfOp{ .input = {} };
            },
            '[' => {
                // `[-]` / `[+]` clears the current cell. Only probe the two
                // following bytes when they are actually in bounds, otherwise a
                // `[` near the end of the buffer would read past it.
                if (self.index + 2 < self.buffer.len and
                    (self.buffer[self.index + 1] == '-' or self.buffer[self.index + 1] == '+') and
                    self.buffer[self.index + 2] == ']')
                {
                    self.index += 3;
                    return BfOp{ .clear = {} };
                } else {
                    self.index += 1;
                    return BfOp{ .open_while = {} };
                }
            },
            ']' => {
                self.index += 1;
                return BfOp{ .close_while = {} };
            },
            else => {
                self.index += 1;
                return BfOp{ .noop = {} };
            },
        }
    }
};

const testing = std.testing;
const expectEqual = testing.expectEqual;
const expect = testing.expect;
const hello_world = @embedFile("helloworld.bf");

test "test tokenizer" {
    var tokenizer = Tokenizer.init(hello_world[0..]);

    try expectEqual(BfOp{ .inc = 8 }, tokenizer.next().?);
    try expectEqual(BfOp.open_while, tokenizer.next().?);
    try expectEqual(BfOp{ .push = 1 }, tokenizer.next().?);
    try expectEqual(BfOp{ .inc = 4 }, tokenizer.next().?);
    try expectEqual(BfOp.open_while, tokenizer.next().?);
    try expectEqual(BfOp{ .push = 1 }, tokenizer.next().?);
    try expectEqual(BfOp{ .inc = 2 }, tokenizer.next().?);
    try expectEqual(BfOp{ .push = 1 }, tokenizer.next().?);
    try expectEqual(BfOp{ .inc = 3 }, tokenizer.next().?);
    try expectEqual(BfOp{ .push = 1 }, tokenizer.next().?);
    try expectEqual(BfOp{ .inc = 3 }, tokenizer.next().?);
    try expectEqual(BfOp{ .push = 1 }, tokenizer.next().?);
    try expectEqual(BfOp{ .inc = 1 }, tokenizer.next().?);
    try expectEqual(BfOp{ .pop = 4 }, tokenizer.next().?);
    try expectEqual(BfOp{ .dec = 1 }, tokenizer.next().?);
    try expectEqual(BfOp.close_while, tokenizer.next().?);
    try expectEqual(BfOp{ .push = 1 }, tokenizer.next().?);
    try expectEqual(BfOp{ .inc = 1 }, tokenizer.next().?);
    try expectEqual(BfOp{ .push = 1 }, tokenizer.next().?);
    try expectEqual(BfOp{ .inc = 1 }, tokenizer.next().?);
    try expectEqual(BfOp{ .push = 1 }, tokenizer.next().?);
    try expectEqual(BfOp{ .dec = 1 }, tokenizer.next().?);
    try expectEqual(BfOp{ .push = 2 }, tokenizer.next().?);
    try expectEqual(BfOp{ .inc = 1 }, tokenizer.next().?);
    try expectEqual(BfOp.open_while, tokenizer.next().?);
    try expectEqual(BfOp{ .pop = 1 }, tokenizer.next().?);
    try expectEqual(BfOp.close_while, tokenizer.next().?);
    try expectEqual(BfOp{ .pop = 1 }, tokenizer.next().?);
    try expectEqual(BfOp{ .dec = 1 }, tokenizer.next().?);
    try expectEqual(BfOp.close_while, tokenizer.next().?);
    try expectEqual(BfOp{ .push = 2 }, tokenizer.next().?);
    try expect(tokenizer.next().? == .print);
    try expectEqual(BfOp{ .push = 1 }, tokenizer.next().?);
    try expectEqual(BfOp{ .dec = 3 }, tokenizer.next().?);
    try expect(tokenizer.next().? == .print);
    try expectEqual(BfOp{ .inc = 7 }, tokenizer.next().?);
    // `..` in the source is merged by `count_same` into a single print op.
    try expectEqual(BfOp{ .print = 2 }, tokenizer.next().?);
    try expectEqual(BfOp{ .inc = 3 }, tokenizer.next().?);
    try expect(tokenizer.next().? == .print);
    try expectEqual(BfOp{ .push = 2 }, tokenizer.next().?);
    try expect(tokenizer.next().? == .print);
    try expectEqual(BfOp{ .pop = 1 }, tokenizer.next().?);
    try expectEqual(BfOp{ .dec = 1 }, tokenizer.next().?);
    try expect(tokenizer.next().? == .print);
    try expectEqual(BfOp{ .pop = 1 }, tokenizer.next().?);
    try expect(tokenizer.next().? == .print);
    try expectEqual(BfOp{ .inc = 3 }, tokenizer.next().?);
    try expect(tokenizer.next().? == .print);
    try expectEqual(BfOp{ .dec = 6 }, tokenizer.next().?);
    try expect(tokenizer.next().? == .print);
    try expectEqual(BfOp{ .dec = 8 }, tokenizer.next().?);
    try expect(tokenizer.next().? == .print);
    try expectEqual(BfOp{ .push = 2 }, tokenizer.next().?);
    try expectEqual(BfOp{ .inc = 1 }, tokenizer.next().?);
    try expect(tokenizer.next().? == .print);
    try expectEqual(BfOp{ .push = 1 }, tokenizer.next().?);
    try expectEqual(BfOp{ .inc = 2 }, tokenizer.next().?);
    try expect(tokenizer.next().? == .print);
    try expect(tokenizer.next() == null);
    try expect(tokenizer.next() == null);
}

pub fn generate(allocator: std.mem.Allocator, buffer: []u8, out_buffer: *Array(u8)) !void {
    const base = @embedFile("base.zig");
    const linebreak: u8 = '\n';

    try out_buffer.appendSlice(allocator, base);

    try out_buffer.append(allocator, linebreak);
    try out_buffer.appendSlice(allocator,
        \\pub fn main(init: std.process.Init) !void {
        \\    const io = init.io;
        \\
        \\    var stdout_buffer: [4096]u8 = undefined;
        \\    var stdout_writer = std.Io.File.Writer.init(.stdout(), io, &stdout_buffer);
        \\    const out = &stdout_writer.interface;
        \\
        \\    var stdin_buffer: [4096]u8 = undefined;
        \\    var stdin_reader = std.Io.File.Reader.init(.stdin(), io, &stdin_buffer);
        \\    const in = &stdin_reader.interface;
        \\
        \\    var data : [std.math.maxInt(u16)]u8 = [1]u8{0} ** std.math.maxInt(u16);
        \\    var state = BrainfuckState.init(&data, out, in);
    );
    try out_buffer.append(allocator, linebreak);
    try out_buffer.append(allocator, linebreak);
    try out_buffer.appendSlice(allocator, "// program starts.");
    try out_buffer.append(allocator, linebreak);
    try out_buffer.append(allocator, linebreak);

    var indent: usize = 4;

    var tokenizer = Tokenizer.init(buffer);
    var printer = [_]u8{0} ** 100;

    while (tokenizer.next()) |result| {
        if (result != BfOp.noop) {
            try add_indent(out_buffer, allocator, indent);
        }
        switch (result) {
            .push => |count| try out_buffer.appendSlice(allocator, try std.fmt.bufPrint(&printer, "state.push_data_pointer({});", .{count})),
            .pop => |count| try out_buffer.appendSlice(allocator, try std.fmt.bufPrint(&printer, "state.pop_data_pointer({});", .{count})),
            // The cell is a u8, so a run of N increments is equivalent to N % 256.
            // Reducing here also keeps the emitted literal within the u8 parameter.
            .inc => |count| try out_buffer.appendSlice(allocator, try std.fmt.bufPrint(&printer, "state.increment_current_data({});", .{count % 256})),
            .dec => |count| try out_buffer.appendSlice(allocator, try std.fmt.bufPrint(&printer, "state.decrement_current_data({});", .{count % 256})),
            .print => |count| try out_buffer.appendSlice(allocator, try std.fmt.bufPrint(&printer, "try state.print_current_data({});", .{count})),
            .input => try out_buffer.appendSlice(allocator, "try state.input_char();"),
            .open_while => {
                try out_buffer.append(allocator, linebreak);
                try add_indent(out_buffer, allocator, indent);
                try out_buffer.appendSlice(allocator, "while(state.is_current_value_pointed_not_0()) {");
                indent += 4;
            },
            .close_while => {
                indent -= 4;
                var i: usize = 0;
                while (i < 4) : (i += 1) {
                    _ = out_buffer.pop();
                }
                try out_buffer.appendSlice(allocator, "}");
                try out_buffer.append(allocator, linebreak);
            },
            .clear => {
                try out_buffer.appendSlice(allocator, "state.clear_current_cell();");
            },
            else => continue,
        }
        try out_buffer.append(allocator, linebreak);
    }

    try out_buffer.append(allocator, linebreak);
    try out_buffer.appendSlice(allocator, "// program ends");
    try out_buffer.append(allocator, linebreak);
    try out_buffer.append(allocator, linebreak);

    try out_buffer.appendSlice(allocator, "    try out.flush();");
    try out_buffer.append(allocator, linebreak);
    try out_buffer.append(allocator, '}');
    try out_buffer.append(allocator, linebreak);
}
