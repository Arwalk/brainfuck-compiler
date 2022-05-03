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

    pub fn is_current_value_pointed_not_0(self: *BrainfuckState) bool {
        return self.data[self.data_pointer] != 0;
    }

    pub fn input_char(self: *BrainfuckState) !void {
        var reader = std.io.getStdIn().reader();
        while(true) {
            var readbuf : [2]u8 = .{0, 0};
            if(reader.readUntilDelimiter(&readbuf, '\n')) |buf| {
                try std.io.getStdOut().writer().print("ok.\n", .{});
                if(buf.len == 0) {
                    self.data[self.data_pointer] = '\n';
                }
                else {
                    self.data[self.data_pointer] = buf[0];
                }
                break;
                
            } else |_| {
                try std.io.getStdOut().writer().print("Expecting only one character.\n", .{});
                while(true) {
                    var clearer = try reader.readUntilDelimiter(&readbuf, '\n');
                    if(clearer.len == 0) {
                        break;
                    }
                }
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
