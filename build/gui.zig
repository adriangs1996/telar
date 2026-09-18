const std = @import("std");
const Application = @import("Application.zig");
const macos_gui = @import("macos_gui.zig");
const linux_gui = @import("linux_gui.zig");

/// Attach the native adapter and its checks: `gui.add(b, app, diagram_helper)`.
pub fn add(b: *std.Build, app: Application, diagram_helper: ?std.Build.LazyPath) ?*std.Build.Module {
    // GPU chrome over the same client behavior as the TUI. It never imports
    // `telar-frontend`. Mermaid rasterization runs in an isolated Rust helper.
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
        const diagram_options = b.addOptions();
        diagram_options.addOptionPath("helper_path", diagram_helper.?);
        gui.addOptions("diagram_renderer_options", diagram_options);
        if (app.modules.target.result.os.tag == .macos) {
            macos_gui.add(b, gui, app.coverage.enabled);
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
                .files = &.{ "src/gui/tests/macos_window.m", "src/gui/tests/macos_host_input.m", "src/gui/tests/macos_diagrams.m", "src/gui/native/wake.c" },
                .flags = &.{ "-fobjc-arc", "-std=c23" },
            });
            macos_gui.add(b, window_test_module, false);
            const window_test = b.addExecutable(.{ .name = "gui-window-test", .root_module = window_test_module });
            b.step("test-gui-window", "Exercise a real macOS window, Metal completion and native keyboard translation").dependOn(&b.addRunArtifact(window_test).step);
        } else {
            const window_test_module = b.createModule(.{ .target = app.modules.target, .optimize = app.modules.optimize, .link_libc = true });
            window_test_module.addCSourceFiles(.{
                .files = &.{ "src/gui/tests/linux_window.c", "src/gui/native/wake.c" },
                .flags = &.{ "-std=c11", "-D_POSIX_C_SOURCE=200809L" },
            });
            linux_gui.add(b, window_test_module, false);
            window_test_module.linkSystemLibrary("dl", .{});
            const window_test = b.addExecutable(.{ .name = "gui-window-test", .root_module = window_test_module });
            const window_run = b.addRunArtifact(window_test);
            const failure_run = b.addRunArtifact(window_test);
            failure_run.addArg("--invalid-frame");
            failure_run.step.dependOn(&window_run.step);
            b.step("test-gui-window", "Exercise a real Wayland window, Vulkan completion, retries and idle stability").dependOn(&failure_run.step);
            const worker_module = b.createModule(.{ .target = app.modules.target, .optimize = app.modules.optimize, .link_libc = true });
            worker_module.addCSourceFiles(.{
                .files = &.{ "src/gui/tests/linux_worker.c", "src/gui/linux/frame_worker.c", "src/gui/native/wake.c" },
                .flags = &.{ "-std=c11", "-D_POSIX_C_SOURCE=200809L" },
            });
            const worker_test = b.addExecutable(.{ .name = "gui-worker-test", .root_module = worker_module });
            b.step("test-gui-worker", "Verify joining a consumer before releasing its borrowed frame").dependOn(&b.addRunArtifact(worker_test).step);
            const keyboard_module = b.createModule(.{ .target = app.modules.target, .optimize = app.modules.optimize, .link_libc = true });
            keyboard_module.addCSourceFiles(.{
                .files = &.{ "src/gui/linux/input_test.c", "src/gui/linux/pointer.c", "src/gui/linux/clipboard.c" },
                .flags = &.{ "-std=c11", "-D_POSIX_C_SOURCE=200809L" },
            });
            keyboard_module.linkSystemLibrary("wayland-client", .{});
            keyboard_module.linkSystemLibrary("xkbcommon", .{});
            linux_gui.addCursor(b, keyboard_module);
            linux_gui.addTextInput(b, keyboard_module);
            linux_gui.addCursorTests(b, .{ .target = app.modules.target, .optimize = app.modules.optimize, .link_libc = true });
            linux_gui.addHostInputTests(b, .{ .target = app.modules.target, .optimize = app.modules.optimize, .link_libc = true });
            linux_gui.addWindowOptionsTests(b, .{ .target = app.modules.target, .optimize = app.modules.optimize, .link_libc = true });
            const keyboard_test = b.addExecutable(.{ .name = "gui-keyboard-test", .root_module = keyboard_module });
            b.step("test-gui-keyboard", "Verify Wayland repeat timing and held key cancellation").dependOn(&b.addRunArtifact(keyboard_test).step);
            const clipboard_module = b.createModule(.{ .target = app.modules.target, .optimize = app.modules.optimize, .link_libc = true });
            clipboard_module.addCSourceFile(.{ .file = b.path("src/gui/linux/clipboard_test.c"), .flags = &.{"-std=c11"} });
            clipboard_module.linkSystemLibrary("wayland-client", .{});
            const clipboard_test = b.addExecutable(.{ .name = "gui-clipboard-test", .root_module = clipboard_module });
            b.step("test-gui-clipboard", "Verify bounded native clipboard transfer ownership and cancellation").dependOn(&b.addRunArtifact(clipboard_test).step);
        }
    }

    return gui_module;
}
