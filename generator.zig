const std = @import("std");
const Array = std.ArrayList;

fn add_indent(out_buffer : anytype, indent: usize) !void {
    var i : usize = 0;
    while (i < indent) : (i+=1) {
        try out_buffer.append(' ');
    }
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