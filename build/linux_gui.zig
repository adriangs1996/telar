const std = @import("std");
const c_flags = @import("c_flags.zig");

/// Wayland through xdg-shell and Vulkan through the system loader. The
/// xdg-shell client code is generated from the protocol the distribution
/// installs, so the machine building Telar needs `wayland-scanner`,
/// `wayland-protocols`, Vulkan and Fontconfig headers, and `glslc`. Example: `linux_gui.add(b, gui, false)`.
pub fn add(b: *std.Build, gui: *std.Build.Module, disable_coverage: bool) void {
    const flags = c_flags.forCoverage(b, &.{"-std=c11"}, disable_coverage);
    addCursorSources(b, gui, flags);
    addTextInput(b, gui);
    addProtocol(b, gui, "stable/xdg-shell/xdg-shell");
    addProtocol(b, gui, "staging/ext-background-effect/ext-background-effect-v1");
    addProtocol(b, gui, "unstable/xdg-decoration/xdg-decoration-unstable-v1");
    gui.addCSourceFiles(.{
        .files = &.{
            "src/gui/linux/window.c",
            "src/gui/linux/accessibility.c",
            "src/gui/linux/accessible.c",
            "src/gui/linux/background_effect.c",
            "src/gui/linux/decoration.c",
            "src/gui/linux/input.c",
            "src/gui/linux/pointer.c",
            "src/gui/linux/clipboard.c",
            "src/gui/linux/font.c",
            "src/gui/linux/frame_worker.c",
            "src/gui/linux/frame_clock.c",
            "src/gui/linux/renderer.c",
            "src/gui/linux/vulkan_device.c",
            "src/gui/linux/vulkan_swapchain.c",
            "src/gui/linux/vulkan_pipeline.c",
            "src/gui/linux/vulkan_resources.c",
            "src/gui/linux/shaders.c",
        },
        .flags = flags,
    });
    compileShader(b, gui, "quad.vert");
    compileShader(b, gui, "quad.frag");
    gui.linkSystemLibrary("xkbcommon", .{});
    gui.linkSystemLibrary("fontconfig", .{});
    gui.linkSystemLibrary("wayland-client", .{});
    gui.linkSystemLibrary("vulkan", .{});
    gui.linkSystemLibrary("atk", .{});
    gui.linkSystemLibrary("atk-bridge-2.0", .{});
    gui.linkSystemLibrary("gio-2.0", .{});
}

/// Cursor requests and retained fallback images, also used by native input tests.
/// Example: linux_gui.addCursor(b, keyboard_module).
pub fn addCursor(b: *std.Build, module: *std.Build.Module) void {
    addCursorSources(b, module, &.{"-std=c11"});
}

/// Shares the Wayland IME and asynchronous clipboard reader with input tests.
/// Example: `linux_gui.addTextInput(b, keyboard_module);`
pub fn addTextInput(b: *std.Build, module: *std.Build.Module) void {
    module.linkSystemLibrary("glib-2.0", .{});
    addProtocol(b, module, "unstable/text-input/text-input-unstable-v3");
    module.addCSourceFiles(.{
        .files = &.{ "src/gui/linux/text_input.c", "src/gui/linux/clipboard_reader.c" },
        .flags = &.{"-std=c11"},
    });
}

/// Verifies IME serials and bounded clipboard reads without a compositor.
/// Example: `linux_gui.addHostInputTests(b, options);`
pub fn addHostInputTests(b: *std.Build, options: std.Build.Module.CreateOptions) void {
    const ime = b.createModule(options);
    addProtocol(b, ime, "unstable/text-input/text-input-unstable-v3");
    ime.addCSourceFile(.{ .file = b.path("src/gui/linux/text_input_test.c"), .flags = &.{"-std=c11"} });
    ime.linkSystemLibrary("wayland-client", .{});
    ime.linkSystemLibrary("glib-2.0", .{});
    const ime_test = b.addExecutable(.{ .name = "gui-ime-test", .root_module = ime });
    b.step("test-gui-ime", "Verify Wayland text composition, byte ranges, serials and focus").dependOn(&b.addRunArtifact(ime_test).step);
    const clipboard = b.createModule(options);
    clipboard.addCSourceFiles(.{ .files = &.{ "src/gui/linux/clipboard_reader.c", "src/gui/linux/clipboard_reader_test.c" }, .flags = &.{"-std=c11"} });
    clipboard.linkSystemLibrary("wayland-client", .{});
    clipboard.linkSystemLibrary("glib-2.0", .{});
    const read_test = b.addExecutable(.{ .name = "gui-clipboard-reader-test", .root_module = clipboard });
    b.step("test-gui-clipboard-reader", "Verify bounded asynchronous clipboard request ownership and cancellation").dependOn(&b.addRunArtifact(read_test).step);
    const accessibility = b.createModule(options);
    accessibility.addCSourceFiles(.{ .files = &.{ "src/gui/linux/accessibility_test.c", "src/gui/linux/accessible.c" }, .flags = &.{"-std=c11"} });
    accessibility.linkSystemLibrary("atk", .{});
    accessibility.linkSystemLibrary("atk-bridge-2.0", .{});
    accessibility.linkSystemLibrary("gio-2.0", .{});
    const accessibility_test = b.addExecutable(.{ .name = "gui-accessibility-test", .root_module = accessibility });
    b.step("test-gui-accessibility", "Verify accessible text, generations and bounded worker actions").dependOn(&b.addRunArtifact(accessibility_test).step);
    const probe = b.addSystemCommand(&.{ "dbus-run-session", "--", "python3" });
    probe.addFileArg(b.path("src/gui/linux/accessibility_probe.py"));
    probe.addArtifactArg(accessibility_test);
    b.step("test-gui-accessibility-bus", "Verify real AT-SPI discovery, text and edit actions over D-Bus").dependOn(&probe.step);
}

fn addCursorSources(b: *std.Build, module: *std.Build.Module, flags: []const []const u8) void {
    addProtocol(b, module, "staging/cursor-shape/cursor-shape-v1");
    addProtocol(b, module, "unstable/tablet/tablet-unstable-v2");
    module.addCSourceFiles(.{
        .files = &.{ "src/gui/linux/cursor.c", "src/gui/linux/cursor_theme.c" },
        .flags = flags,
    });
    module.linkSystemLibrary("wayland-cursor", .{});
    module.linkSystemLibrary("wayland-client", .{});
}

/// Runs cursor listeners against bounded protocol doubles, without a compositor.
/// Example: linux_gui.addCursorTests(b, .{ .target = target, .link_libc = true }).
pub fn addCursorTests(b: *std.Build, options: std.Build.Module.CreateOptions) void {
    const module = b.createModule(options);
    addProtocol(b, module, "staging/cursor-shape/cursor-shape-v1");
    addProtocol(b, module, "unstable/tablet/tablet-unstable-v2");
    module.addCSourceFile(.{ .file = b.path("src/gui/linux/cursor_test.c"), .flags = &.{"-std=c11"} });
    module.linkSystemLibrary("wayland-client", .{});
    module.linkSystemLibrary("wayland-cursor", .{});
    const executable = b.addExecutable(.{ .name = "gui-pointer-test", .root_module = module });
    b.step("test-gui-pointer", "Verify native pointer serials, shapes, focus and retained cursor resources").dependOn(&b.addRunArtifact(executable).step);
}

/// Exercises decoration and blur negotiation without a running compositor.
/// Example: linux_gui.addWindowOptionsTests(b, .{ .target = target, .link_libc = true }).
pub fn addWindowOptionsTests(b: *std.Build, options: std.Build.Module.CreateOptions) void {
    const module = b.createModule(options);
    addProtocol(b, module, "stable/xdg-shell/xdg-shell");
    addProtocol(b, module, "unstable/xdg-decoration/xdg-decoration-unstable-v1");
    addProtocol(b, module, "staging/ext-background-effect/ext-background-effect-v1");
    module.addCSourceFile(.{ .file = b.path("src/gui/linux/window_options_test.c"), .flags = &.{"-std=c11"} });
    module.linkSystemLibrary("wayland-client", .{});
    const executable = b.addExecutable(.{ .name = "gui-window-options-test", .root_module = module });
    b.step("test-gui-window-options", "Verify native titlebar and background effect negotiation").dependOn(&b.addRunArtifact(executable).step);
}

fn addProtocol(b: *std.Build, module: *std.Build.Module, name: []const u8) void {
    const path = b.fmt("/usr/share/wayland-protocols/{s}.xml", .{name});
    const stem = std.fs.path.basename(name);
    const header = b.addSystemCommand(&.{ "wayland-scanner", "client-header", path });
    const header_file = header.addOutputFileArg(b.fmt("{s}-client-protocol.h", .{stem}));
    const code = b.addSystemCommand(&.{ "wayland-scanner", "private-code", path });
    const code_file = code.addOutputFileArg(b.fmt("{s}-protocol.c", .{stem}));
    module.addIncludePath(header_file.dirname());
    module.addCSourceFile(.{ .file = code_file, .flags = &.{"-std=c11"} });
}

// Generate dependency-tracked C initializers from the GLSL sources.
fn compileShader(b: *std.Build, module: *std.Build.Module, shader: []const u8) void {
    const compile = b.addSystemCommand(&.{ "glslc", "--target-env=vulkan1.3", "-O", "-mfmt=c" });
    compile.addFileArg(b.path(b.fmt("src/gui/shaders/{s}", .{shader})));
    compile.addArg("-o");
    const output = compile.addOutputFileArg(b.fmt("{s}.inc", .{shader}));
    module.addIncludePath(output.dirname());
}
