const std = @import("std");
const Array = std.ArrayList;

fn add_indent(out_buffer : anytype, indent: usize) !void {
    var i : usize = 0;
    while (i < indent) : (i+=1) {
        try out_buffer.append(' ');
    }
}

const BfOpEnum = enum {
    push,
    pop,
    inc,
    dec,
    print,
    input,
    open_while,
    close_while,
    noop
};

const BfOp = union(BfOpEnum) {
    push : usize,
    pop : usize,
    inc : usize,
    dec : usize,
    print,
    input,
    open_while,
    close_while,
    noop,
};

const Tokenizer = struct {
    buffer : []const u8,
    index : usize,

    pub fn init(buffer : []const u8) Tokenizer {
        return .{.buffer = buffer, .index = 0 };
    }

    fn count_same(self: *Tokenizer, char : u8) usize {
        var count : usize = 0;
        while (self.index < self.buffer.len) : (self.index += 1) {
            if(self.buffer[self.index] == char) {
                count += 1;
            }
            else {
                break;
            }
        }
        return count;
    }

    pub fn next(self: *Tokenizer) ?BfOp {
        
        if(self.index > self.buffer.len) {
            return null;
        }
        
        switch(self.buffer[self.index]) {
            '>' => return BfOp{.push = self.count_same(self.buffer[self.index])},
            '<' => return BfOp{.pop = self.count_same(self.buffer[self.index])},
            '+' => return BfOp{.inc = self.count_same(self.buffer[self.index])},
            '-' => return BfOp{.dec = self.count_same(self.buffer[self.index])},
            '.' => {
                self.index += 1;
                return BfOp{.print = {}};
            },
            ',' => {
                self.index += 1;
                return BfOp{.input = {}};
            },
            '[' => {
                self.index += 1;
                return BfOp{.open_while = {}};
            },
            ']' => {
                self.index += 1;
                return BfOp{.close_while = {}};
            },
            else => {
                self.index += 1;
                return BfOp{.noop = {}};
            }
        }
    }
};

const testing = std.testing;
const expectEqual = testing.expectEqual;
const hello_world = @embedFile("helloworld.bf");

test "test tokenizer" {
    var tokenizer = Tokenizer.init(hello_world[0..]);

    try expectEqual(BfOp{.inc = 8}, tokenizer.next().?);
    try expectEqual(BfOp.open_while , tokenizer.next().?);
    try expectEqual(BfOp{.push = 1}, tokenizer.next().?);
    try expectEqual(BfOp{.inc = 4}, tokenizer.next().?);
    try expectEqual(BfOp.open_while , tokenizer.next().?);
    try expectEqual(BfOp{.push = 1}, tokenizer.next().?);
    try expectEqual(BfOp{.inc = 2}, tokenizer.next().?);
    try expectEqual(BfOp{.push = 1}, tokenizer.next().?);
    try expectEqual(BfOp{.inc = 3}, tokenizer.next().?);
    try expectEqual(BfOp{.push = 1}, tokenizer.next().?);
    try expectEqual(BfOp{.inc = 3}, tokenizer.next().?);
    try expectEqual(BfOp{.push = 1}, tokenizer.next().?);
    try expectEqual(BfOp{.inc = 1}, tokenizer.next().?);
    try expectEqual(BfOp{.pop = 4}, tokenizer.next().?);
    try expectEqual(BfOp{.dec = 1}, tokenizer.next().?);
    try expectEqual(BfOp.close_while, tokenizer.next().?);
    try expectEqual(BfOp{.push = 1}, tokenizer.next().?);
    try expectEqual(BfOp{.inc = 1}, tokenizer.next().?);
    try expectEqual(BfOp{.push = 1}, tokenizer.next().?);
    try expectEqual(BfOp{.inc = 1}, tokenizer.next().?);
    try expectEqual(BfOp{.push = 1}, tokenizer.next().?);
    try expectEqual(BfOp{.dec = 1}, tokenizer.next().?);
    try expectEqual(BfOp{.push = 2}, tokenizer.next().?);
    try expectEqual(BfOp{.inc = 1}, tokenizer.next().?);
    try expectEqual(BfOp.open_while , tokenizer.next().?);
    try expectEqual(BfOp{.pop = 1}, tokenizer.next().?);
    try expectEqual(BfOp.close_while, tokenizer.next().?);
    try expectEqual(BfOp{.pop = 1}, tokenizer.next().?);
    try expectEqual(BfOp{.dec = 1}, tokenizer.next().?);
    try expectEqual(BfOp.close_while, tokenizer.next().?);
    try expectEqual(BfOp{.push = 2}, tokenizer.next().?);
    try expectEqual(BfOp.print, tokenizer.next().?);
    try expectEqual(BfOp{.push = 1}, tokenizer.next().?);
    try expectEqual(BfOp{.dec = 3}, tokenizer.next().?);
    try expectEqual(BfOp.print, tokenizer.next().?);
    try expectEqual(BfOp{.inc = 7}, tokenizer.next().?);
    try expectEqual(BfOp.print, tokenizer.next().?);
    try expectEqual(BfOp.print, tokenizer.next().?);
    try expectEqual(BfOp{.inc = 3}, tokenizer.next().?);
    try expectEqual(BfOp.print, tokenizer.next().?);
    try expectEqual(BfOp{.push = 2}, tokenizer.next().?);
    try expectEqual(BfOp.print, tokenizer.next().?);
    try expectEqual(BfOp{.pop = 1}, tokenizer.next().?);
    try expectEqual(BfOp{.dec = 1}, tokenizer.next().?);
    try expectEqual(BfOp.print, tokenizer.next().?);
    try expectEqual(BfOp{.pop = 1}, tokenizer.next().?);
    try expectEqual(BfOp.print, tokenizer.next().?);
    try expectEqual(BfOp{.inc = 3}, tokenizer.next().?);
    try expectEqual(BfOp.print, tokenizer.next().?);
    try expectEqual(BfOp{.dec = 6}, tokenizer.next().?);
    try expectEqual(BfOp.print, tokenizer.next().?);
    try expectEqual(BfOp{.dec = 8}, tokenizer.next().?);
    try expectEqual(BfOp.print, tokenizer.next().?);
    try expectEqual(BfOp{.push = 2}, tokenizer.next().?);
    try expectEqual(BfOp{.inc = 1}, tokenizer.next().?);
    try expectEqual(BfOp.print, tokenizer.next().?);
    try expectEqual(BfOp{.push = 1}, tokenizer.next().?);
    try expectEqual(BfOp{.inc = 2}, tokenizer.next().?);
    try expectEqual(BfOp.print, tokenizer.next().?);

}

pub fn generate(buffer : []u8, out_buffer : *Array(u8)) !void {
    const base = @embedFile("base.zig");

    try out_buffer.appendSlice(base);

    
    try out_buffer.appendSlice("pub fn main() !void {");
    try out_buffer.appendSlice("    var state = BrainfuckState.init();");

    var indent : usize = 4;
    var linebreak : u8 = '\n';

    for(buffer) |char| {
        try add_indent(out_buffer, indent);
        switch(char) {
            '>' => try out_buffer.appendSlice("state.push_data_pointer(1);"),
            '<' => try out_buffer.appendSlice("state.pop_data_pointer(1);"),
            '+' => try out_buffer.appendSlice("state.increment_current_data(1);"),
            '-' => try out_buffer.appendSlice("state.decrement_current_data(1);"),
            '.' => try out_buffer.appendSlice("try state.print_current_data();"),
            ',' => try out_buffer.appendSlice("try state.input_char();"),
            '[' => {
                try out_buffer.append(linebreak);
                try add_indent(out_buffer, indent);
                try out_buffer.appendSlice("while(state.data[state.data_pointer] != 0) {");
                indent += 4;
            },
            ']' => {
                indent -= 4;
                var i : usize = 0;
                while (i < 4) : (i+=1) {
                    _ = out_buffer.pop();
                }
                try out_buffer.appendSlice("}");
                try out_buffer.append(linebreak);
            },
            else => continue
        }
        try out_buffer.append(linebreak);
    }
    try out_buffer.append('}');
    try out_buffer.append(linebreak);
}