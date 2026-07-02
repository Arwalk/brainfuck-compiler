const std = @import("std");
const Build = std.Build;
const generator = @import("generator.zig");

pub fn build(b: *Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardOptimizeOption(.{});

    // The build graph owns an arena allocator and the `Io` instance the build
    // system uses for filesystem access.
    const gpa = b.allocator;
    const io = b.graph.io;

    if (b.graph.environ_map.get("BF_FILE_PATH")) |path| {
        const file_name = std.fs.path.basename(path);
        const temp_file_full_path = try std.fmt.allocPrint(gpa, "generated/{s}.zig", .{file_name});

        const buffer = try b.build_root.handle.readFileAlloc(io, path, gpa, .unlimited);

        var out_buffer: std.ArrayList(u8) = .empty;
        try generator.generate(gpa, buffer, &out_buffer);

        try b.build_root.handle.writeFile(io, .{
            .sub_path = temp_file_full_path,
            .data = out_buffer.items,
        });

        const exe = b.addExecutable(.{
            .name = file_name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(temp_file_full_path),
                .target = target,
                .optimize = mode,
            }),
        });

        b.installArtifact(exe);
    }

    const tests_generator = b.addTest(.{
        .name = "generator",
        .root_module = b.createModule(.{
            .root_source_file = b.path("generator.zig"),
            .target = target,
            .optimize = mode,
        }),
    });

    const run_tests = b.addRunArtifact(tests_generator);
    b.step("test", "run all tests").dependOn(&run_tests.step);
}
