const std = @import("std");

const BrainfuckState = struct {
    data : [std.math.maxInt(u16)]u8,
    data_pointer: u16,


    pub fn push_data_pointer(self: *BrainfuckState) void {
        self.data_pointer +%= 1;
    }

    pub fn pop_data_pointer(self: *BrainfuckState) void {
        self.data_pointer -%= 1;
    }

    pub fn increment_current_data(self: *BrainfuckState) void {
        self.data[self.data_pointer] +%= 1;
    }

    pub fn decrement_current_data(self: *BrainfuckState) void {
        self.data[self.data_pointer] -%= 1;
    }

    pub fn print_current_data(self: *BrainfuckState) !void {
        try std.io.getStdOut().writer().print("{c}", .{self.data[self.data_pointer]});
    }

    pub fn input_char(self: *BrainfuckState) !void {
        var buf : [1]u8 = undefined;
        _ = try std.io.getStdIn().reader().readUntilDelimiterOrEof(buf[0..], '\n');            
        self.data[self.data_pointer] = buf[0];
    }

    pub fn is_current_data_zero(self: BrainfuckState) bool {
        return self.data[self.data_pointer] == 0;
    }

    pub fn init() BrainfuckState {
        return .{
            .data = [1]u8{0} ** 65535,
            .data_pointer = 0
        };
    }
};
