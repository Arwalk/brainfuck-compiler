const std = @import("std");
const Builder = std.build.Builder;
const generator = @import("generator.zig");

fn concatAndReturnBuffer(allocator: std.mem.Allocator, one: []const u8, two: []const u8) !std.Buffer {
    var b = try std.Buffer.init(allocator, one);
    try b.append(two);
    return b;
}

pub fn build(b: *Builder) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = general_purpose_allocator.allocator();
    
    const file_path = std.process.getEnvVarOwned(gpa, "BF_FILE_PATH") catch null;

    if(file_path) |path| {
        const file_name = std.fs.path.basename(path);
        var temp_file_name : []u8 = try std.fmt.allocPrint(gpa, "{s}.zig", .{file_name});
        var temp_file_full_path : []u8 = try std.fmt.allocPrint(gpa, "generated/{s}", .{temp_file_name});

        var file_handle = try std.fs.cwd().openFile(path, .{ .mode=.read_only });
        defer file_handle.close();

        var buffer = try file_handle.readToEndAlloc(gpa, std.math.maxInt(u16));

        var out_buffer = std.ArrayList(u8).init(gpa);
        try generator.generate(buffer, &out_buffer);

        var temp_file_handler = try std.fs.cwd().createFile(temp_file_full_path, .{});
        temp_file_handler.close();
        temp_file_handler = try std.fs.cwd().openFile(temp_file_full_path, .{.mode = .write_only});

        try temp_file_handler.writeAll(out_buffer.items);
        temp_file_handler.close();

        const exe = b.addExecutable("program", temp_file_full_path);
        
        exe.setTarget(target);
        exe.setBuildMode(mode);
        exe.install();

        const run_cmd = exe.run();
        run_cmd.step.dependOn(b.getInstallStep());

        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
    }
    
    var tests_generator = b.addTest("generator.zig");
    const test_step = b.step("test", "run all tests");
    test_step.dependOn(&tests_generator.step);

}