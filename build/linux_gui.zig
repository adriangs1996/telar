const std = @import("std");
const c_flags = @import("c_flags.zig");

/// Wayland through xdg-shell and Vulkan through the system loader. The
/// xdg-shell client code is generated from the protocol the distribution
/// installs, so the machine building Telar needs `wayland-scanner`,
/// `wayland-protocols`, Vulkan and Fontconfig headers, and `glslc`. Example: `linux_gui.add(b, gui, false)`.
pub fn add(b: *std.Build, gui: *std.Build.Module, disable_coverage: bool) void {
    const flags = c_flags.forCoverage(b, &.{"-std=c11"}, disable_coverage);
    addProtocol(b, gui, "stable/xdg-shell/xdg-shell");
    addProtocol(b, gui, "staging/ext-background-effect/ext-background-effect-v1");
    gui.addCSourceFiles(.{
        .files = &.{
            "src/gui/linux/window.c",
            "src/gui/linux/background_effect.c",
            "src/gui/linux/input.c",
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
