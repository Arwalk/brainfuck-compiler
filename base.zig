const std = @import("std");
const io = std.io;
const stdout = std.io.getStdOut().writer();
const stdin = std.io.getStdIn().reader();

const BrainfuckState = struct {
    data_pointer: [*]u8,

    pub fn push_data_pointer(self: *BrainfuckState, value: usize) void {
        self.data_pointer += value;
    }

    pub fn pop_data_pointer(self: *BrainfuckState, value: usize) void {
        self.data_pointer -= value;
    }

    pub fn increment_current_data(self: *BrainfuckState, value: u8) void {
        self.data_pointer[0] +%= value;
    }

    pub fn decrement_current_data(self: *BrainfuckState, value: u8) void {
        self.data_pointer[0] -%= value;
    }

    pub fn print_current_data(self: *BrainfuckState, count: usize) !void {
        try stdout.writeByteNTimes(self.data_pointer[0], count);
    }

    pub fn is_current_value_pointed_not_0(self: *BrainfuckState) bool {
        return self.data_pointer[0] != 0;
    }

    pub fn clear_current_cell(self: *BrainfuckState) void {
        self.data_pointer[0] = 0;
    }

    pub fn input_char(self: *BrainfuckState) !void {
        while (true) {
            var readbuf: [2]u8 = .{ 0, 0 };
            if (stdin.readUntilDelimiter(&readbuf, '\n')) |buf| {
                try stdout.print("ok.\n", .{});
                if (buf.len == 0) {
                    self.data_pointer[0] = '\n';
                } else {
                    self.data_pointer[0] = buf[0];
                }
                break;
            } else |_| {
                try stdout.print("Expecting only one character.\n", .{});
                while (true) {
                    const clearer = try stdin.readUntilDelimiter(&readbuf, '\n');
                    if (clearer.len == 0) {
                        break;
                    }
                }
            }
        }
    }

    pub fn init(data: [*]u8) BrainfuckState {
        const struc = BrainfuckState{ .data_pointer = data };

        return struc;
    }
};
