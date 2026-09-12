const std = @import("std");
const Application = @import("Application.zig");

/// Register frontend execution experiments: `experiments.add(b, app)`.
pub fn add(b: *std.Build, app: Application) void {
    const experiment_module = b.createModule(.{
        .root_source_file = b.path("exper.zig"),
        .target = app.modules.target,
        .optimize = app.modules.optimize,
        .link_libc = true,
    });
    experiment_module.addImport("telar-frontend", app.modules.frontend);
    experiment_module.addImport("telar-core", app.modules.core);
    const experiment = b.addExecutable(.{ .name = "exper", .root_module = experiment_module });
    const run_experiment = b.addRunArtifact(experiment);
    b.step("exper", "Run the frontend execution experiment").dependOn(&run_experiment.step);
    if (app.modules.target.result.os.tag == .macos) {
        const native_module = b.createModule(.{
            .root_source_file = b.path("exper_native.zig"),
            .target = app.modules.target,
            .optimize = app.modules.optimize,
            .link_libc = true,
        });
        native_module.addImport("telar-frontend", app.modules.frontend);
        native_module.addImport("telar-core", app.modules.core);
        native_module.addCSourceFile(.{ .file = b.path("exper/native.m"), .flags = &.{"-fobjc-arc"} });
        native_module.linkFramework("AppKit", .{});
        const native = b.addExecutable(.{ .name = "exper-native", .root_module = native_module });
        b.step("build-exper-native", "Build the macOS frontend experiment").dependOn(&native.step);
        b.step("exper-native", "Run the macOS frontend experiment").dependOn(&b.addRunArtifact(native).step);
    }
    const experiment_tests = b.addTest(.{ .root_module = experiment_module });
    b.step("test-exper", "Test the frontend execution experiment").dependOn(&b.addRunArtifact(experiment_tests).step);
}
