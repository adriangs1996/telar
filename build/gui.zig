const std = @import("std");
const Application = @import("Application.zig");
const c_flags = @import("c_flags.zig");
const linux_gui = @import("linux_gui.zig");

/// Attach the native adapter and its checks: `gui.add(b, app)`.
pub fn add(b: *std.Build, app: Application) ?*std.Build.Module {
    // GPU chrome over the same client behavior as the TUI. It never imports
    // `telar-frontend`; the window and Metal backend are Objective-C compiled
    // by Zig, so the toolchain stays a Zig compiler and the macOS SDK.
    var gui_module: ?*std.Build.Module = null;
    if (app.modules.target.result.os.tag == .macos or app.modules.target.result.os.tag == .linux) {
        const gui = b.createModule(.{
            .root_source_file = b.path("src/gui/gui.zig"),
            .target = app.modules.target,
            .optimize = app.modules.optimize,
            .link_libc = true,
        });
        gui.addCSourceFile(.{ .file = b.path("src/gui/native/wake.c"), .flags = &.{} });
        gui.addImport("freetype", app.modules.freetype);
        gui.addImport("assets", app.modules.assets);
        gui.addImport("telar-client", app.modules.client);
        gui.addImport("telar-core", app.modules.core);
        if (app.modules.target.result.os.tag == .macos) {
            gui.addCSourceFile(.{
                .file = b.path("src/gui/macos/window.m"),
                .flags = c_flags.forCoverage(b, &.{ "-fobjc-arc", "-std=c23" }, app.coverage.enabled),
            });
            gui.linkFramework("AppKit", .{});
            gui.linkFramework("Metal", .{});
            gui.linkFramework("QuartzCore", .{});
        } else {
            linux_gui.add(b, gui, app.coverage.enabled);
        }
        app.exe.root_module.addImport("telar-gui", gui);
        const run_gui = b.addRunArtifact(app.exe);
        run_gui.addArg("gui");
        if (b.args) |args| {
            run_gui.addArgs(args);
        }
        b.step("gui", "Run the native client through `telar gui`").dependOn(&run_gui.step);
        gui_module = gui;
        const gui_tests = b.addTest(.{ .root_module = gui });
        app.coverage.instrumentTest(gui_tests);
        b.step("test-gui", "Run the native client tests").dependOn(&b.addRunArtifact(gui_tests).step);
        if (app.modules.target.result.os.tag == .macos) {
            const window_test_module = b.createModule(.{ .target = app.modules.target, .optimize = app.modules.optimize, .link_libc = true });
            window_test_module.addIncludePath(b.path("src/gui/native"));
            window_test_module.addCSourceFiles(.{
                .files = &.{ "src/gui/tests/macos_window.m", "src/gui/macos/window.m", "src/gui/native/wake.c" },
                .flags = &.{ "-fobjc-arc", "-std=c23" },
            });
            window_test_module.linkFramework("AppKit", .{});
            window_test_module.linkFramework("Metal", .{});
            window_test_module.linkFramework("QuartzCore", .{});
            const window_test = b.addExecutable(.{ .name = "gui-window-test", .root_module = window_test_module });
            b.step("test-gui-window", "Exercise a real macOS window, Metal completion and native keyboard translation").dependOn(&b.addRunArtifact(window_test).step);
        }
    }

    return gui_module;
}
