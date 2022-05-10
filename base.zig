const std = @import("std");

const BrainfuckState = struct {
    data : [std.math.maxInt(u16)]u8,
    data_pointer: [*]u8,


    pub fn push_data_pointer(self: *BrainfuckState, value : usize) void {
        self.data_pointer += value;
    }

    pub fn pop_data_pointer(self: *BrainfuckState, value : usize) void {
        self.data_pointer -= value;
    }

    pub fn increment_current_data(self: *BrainfuckState, value : u8) void {
        self.data_pointer[0] +%= value;
    }

    pub fn decrement_current_data(self: *BrainfuckState, value : u8) void {
        self.data_pointer[0] -%= value;
    }

    pub fn print_current_data(self: *BrainfuckState, count : usize) !void {
        try std.io.getStdOut().writer().writeByteNTimes(self.data_pointer[0], count);
    }

    pub fn is_current_value_pointed_not_0(self: *BrainfuckState) bool {
        return self.data_pointer[0] != 0;
    }

    pub fn input_char(self: *BrainfuckState) !void {
        var reader = std.io.getStdIn().reader();
        while(true) {
            var readbuf : [2]u8 = .{0, 0};
            if(reader.readUntilDelimiter(&readbuf, '\n')) |buf| {
                try std.io.getStdOut().writer().print("ok.\n", .{});
                if(buf.len == 0) {
                    self.data_pointer[0] = '\n';
                }
                else {
                    self.data_pointer[0] = buf[0];
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
        var temp = [1]u8{0};
        var struc = BrainfuckState{
            .data = [1]u8{0} ** 65535,
            .data_pointer = &temp
        };
        struc.data_pointer = &struc.data;

        return struc;
    }
};
