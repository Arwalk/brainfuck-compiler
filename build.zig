const std = @import("std");
const Build = std.Build;
const generator = @import("generator.zig");

fn concatAndReturnBuffer(allocator: std.mem.Allocator, one: []const u8, two: []const u8) !std.Buffer {
    var b = try std.Buffer.init(allocator, one);
    try b.append(two);
    return b;
}

pub fn build(b: *Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardOptimizeOption(.{});
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = general_purpose_allocator.allocator();

    const file_path = std.process.getEnvVarOwned(gpa, "BF_FILE_PATH") catch null;

    if (file_path) |path| {
        const file_name = std.fs.path.basename(path);
        const temp_file_name: []u8 = try std.fmt.allocPrint(gpa, "{s}.zig", .{file_name});
        const temp_file_full_path: []u8 = try std.fmt.allocPrint(gpa, "generated/{s}", .{temp_file_name});

        var file_handle = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
        defer file_handle.close();

        const buffer = try file_handle.readToEndAlloc(gpa, std.math.maxInt(u16));

        var out_buffer = std.ArrayList(u8).init(gpa);
        try generator.generate(buffer, &out_buffer);

        var temp_file_handler = try std.fs.cwd().createFile(temp_file_full_path, .{});
        temp_file_handler.close();
        temp_file_handler = try std.fs.cwd().openFile(temp_file_full_path, .{ .mode = .write_only });

        try temp_file_handler.writeAll(out_buffer.items);
        temp_file_handler.close();

        const exe = b.addExecutable(.{
            .name = file_name,
            .root_module = b.addModule(file_name, .{
                .root_source_file = b.path(temp_file_full_path),
                .target = target,
                .optimize = mode,
            }),
        });

        b.installArtifact(exe);
    }

    const tests_generator = b.addTest(.{
        .name = "generator",
        .root_module = b.addModule("generator", .{
            .root_source_file = b.path("generator.zig"),
            .target = target,
            .optimize = mode,
        }),
    });
    b.step("test", "run all tests").dependOn(&tests_generator.step);
}
