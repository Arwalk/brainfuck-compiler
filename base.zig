const std = @import("std");
const Io = std.Io;

const BrainfuckState = struct {
    data_pointer: [*]u8,
    writer: *Io.Writer,
    reader: *Io.Reader,

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
        try self.writer.splatByteAll(self.data_pointer[0], count);
    }

    pub fn is_current_value_pointed_not_0(self: *BrainfuckState) bool {
        return self.data_pointer[0] != 0;
    }

    pub fn clear_current_cell(self: *BrainfuckState) void {
        self.data_pointer[0] = 0;
    }

    pub fn input_char(self: *BrainfuckState) !void {
        while (true) {
            const line = self.reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    // Diagnostics go to stderr so they never pollute the
                    // program's own output on stdout.
                    std.debug.print("Expecting only one character.\n", .{});
                    _ = self.reader.discardDelimiterInclusive('\n') catch {};
                    continue;
                },
                else => return err,
            };

            // `line` still contains the trailing '\n'; drop it before inspecting.
            const content = line[0 .. line.len - 1];
            if (content.len > 1) {
                std.debug.print("Expecting only one character.\n", .{});
                continue;
            }

            std.debug.print("ok.\n", .{});
            self.data_pointer[0] = if (content.len == 0) '\n' else content[0];
            break;
        }
    }

    pub fn init(data: [*]u8, writer: *Io.Writer, reader: *Io.Reader) BrainfuckState {
        return BrainfuckState{ .data_pointer = data, .writer = writer, .reader = reader };
    }
};
