const std = @import("std");
const build = @import("../build.zig");
const Coverage = @This();

enabled: bool,
runtime_path: ?[]const u8,

pub fn init(b: *std.Build) Coverage {
    const enabled = b.option(bool, "coverage", "Enable zig-cov instrumentation") orelse false;
    const runtime_path = b.option([]const u8, "coverage-rt", "Path to zig-cov-rt.o");
    if (enabled and runtime_path == null) {
        std.debug.panic("-Dcoverage requires -Dcoverage-rt=<path>", .{});
    }
    return .{
        .enabled = enabled,
        .runtime_path = runtime_path,
    };
}

pub fn instrumentModule(coverage: Coverage, module: *std.Build.Module) void {
    if (coverage.enabled) {
        module.fuzz = true;
    }
}

pub fn instrumentTest(coverage: Coverage, test_executable: *std.Build.Step.Compile) void {
    if (!coverage.enabled) {
        return;
    }
    test_executable.use_llvm = true;
    test_executable.root_module.fuzz = true;
    test_executable.root_module.link_libc = true;
    test_executable.root_module.addObjectFile(.{ .cwd_relative = coverage.runtime_path.? });
}

pub fn excludeCSourceCoverage(coverage: Coverage, b: *std.Build, module: *std.Build.Module) void {
    if (!coverage.enabled) {
        return;
    }
    for (module.link_objects.items) |link_object| switch (link_object) {
        .c_source_file => |source| source.flags = build.cFlags(b, source.flags, true),
        .c_source_files => |sources| sources.flags = build.cFlags(b, sources.flags, true),
        else => {},
    };
}
