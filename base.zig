const std = @import("std");
const Io = std.Io;

/// Writes `value` to stdout `count` times. Runs of `.` in the source are
/// coalesced into a single call.
fn write_cell(writer: *Io.Writer, value: u8, count: usize) !void {
    try writer.splatByteAll(value, count);
}

/// `[>]`: move right to the nearest zero cell. Uses a vectorized element search
/// instead of stepping one cell at a time.
fn scan_right(comptime T: type, data: []T, ptr: [*]T) [*]T {
    const idx = (@intFromPtr(ptr) - @intFromPtr(data.ptr)) / @sizeOf(T);
    return ptr + std.mem.indexOfScalar(T, data[idx..], 0).?;
}

/// `[<]`: move left to the nearest zero cell.
fn scan_left(comptime T: type, data: []T, ptr: [*]T) [*]T {
    const idx = (@intFromPtr(ptr) - @intFromPtr(data.ptr)) / @sizeOf(T);
    return data.ptr + std.mem.lastIndexOfScalar(T, data[0 .. idx + 1], 0).?;
}

/// Reads a single byte for the brainfuck `,` command. Input is line-buffered:
/// exactly one character per line is expected. Diagnostics go to stderr so they
/// never pollute the program's own output on stdout.
fn read_cell(reader: *Io.Reader) !u8 {
    while (true) {
        const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                std.debug.print("Expecting only one character.\n", .{});
                _ = reader.discardDelimiterInclusive('\n') catch {};
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
        return if (content.len == 0) '\n' else content[0];
    }
}
