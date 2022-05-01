const std = @import("std");

const BrainfuckState = struct {
    data : [std.math.maxInt(u16)]u8,
    data_pointer: u16,


    pub fn push_data_pointer(self: *BrainfuckState, value : u16) void {
        self.data_pointer +%= value;
    }

    pub fn pop_data_pointer(self: *BrainfuckState, value : u16) void {
        self.data_pointer -%= value;
    }

    pub fn increment_current_data(self: *BrainfuckState, value : u8) void {
        self.data[self.data_pointer] +%= value;
    }

    pub fn decrement_current_data(self: *BrainfuckState, value : u8) void {
        self.data[self.data_pointer] -%= value;
    }

    pub fn print_current_data(self: *BrainfuckState) !void {
        try std.io.getStdOut().writer().print("{c}", .{self.data[self.data_pointer]});
    }

    pub fn input_char(self: *BrainfuckState) !void {
        var buf : [2]u8 = undefined;
        while(true) {
            if(std.io.getStdIn().reader().readUntilDelimiterOrEof(buf[0..], '\n')) |_| {
                self.data[self.data_pointer] = buf[0];
                break;
            } else |_| {
                std.io.getStdOut().writer().print("Expecting only one character.\n", .{}) catch unreachable;
            }
        }
    }

    pub fn init() BrainfuckState {
        return .{
            .data = [1]u8{0} ** 65535,
            .data_pointer = 0
        };
    }
};
