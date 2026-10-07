const std = @import("std");
const linux_gui = @import("linux_gui.zig");

pub fn addMacos(b: *std.Build, module: *std.Build.Module) void {
    module.addCSourceFile(.{ .file = b.path("lib/window/native/wake.c"), .flags = &.{} });
    module.addIncludePath(b.path("lib/window/native"));
}

pub fn addWayland(b: *std.Build, module: *std.Build.Module) void {
    const protocol = b.createModule(.{
        .target = module.resolved_target.?,
        .optimize = module.optimize.?,
        .link_libc = true,
    });
    linux_gui.addProtocol(b, protocol, "stable/xdg-shell/xdg-shell");
    linux_gui.addProtocol(b, protocol, "unstable/xdg-decoration/xdg-decoration-unstable-v1");
    linux_gui.addProtocol(b, protocol, "staging/ext-background-effect/ext-background-effect-v1");
    linux_gui.addProtocol(b, protocol, "unstable/text-input/text-input-unstable-v3");
    linux_gui.addProtocol(b, protocol, "staging/cursor-shape/cursor-shape-v1");
    linux_gui.addProtocol(b, protocol, "unstable/tablet/tablet-unstable-v2");
    const libraries = [_][]const u8{ "wayland-client", "wayland-cursor", "xkbcommon", "glib-2.0", "atk", "atk-bridge-2.0", "gio-2.0" };
    const include_flags = b.run(&.{ "pkg-config", "--cflags", "wayland-cursor", "xkbcommon", "glib-2.0", "atk", "atk-bridge-2.0", "gio-2.0" });
    var flags: std.ArrayList([]const u8) = .empty;
    flags.append(b.allocator, "-std=c11") catch @panic("OOM");
    var tokens = std.mem.tokenizeAny(u8, include_flags, " \t\r\n");
    while (tokens.next()) |flag| {
        flags.append(b.allocator, flag) catch @panic("OOM");
    }

    for ([_][]const u8{ "vert", "frag" }) |stage| {
        const shader = b.addSystemCommand(&.{ "glslc", "-mfmt=num" });
        shader.addFileArg(b.path(b.fmt("lib/window/shaders/quad.{s}", .{stage})));
        shader.addArg("-o");
        const output = shader.addOutputFileArg(b.fmt("quad.{s}.inc", .{stage}));
        protocol.addIncludePath(output.dirname());
    }
    protocol.addCSourceFiles(.{
        .files = &.{
            "lib/window/native/wake.c",
            "lib/window/vulkan/vulkan_device.c",
            "lib/window/vulkan/vulkan_swapchain.c",
            "lib/window/vulkan/vulkan_pipeline.c",
            "lib/window/vulkan/vulkan_resources.c",
            "lib/window/vulkan/vulkan_images.c",
            "lib/window/vulkan/shaders.c",

            "lib/window/linux/cursor.c",
            "lib/window/linux/cursor_theme.c",
            "lib/window/linux/outputs.c",
            "lib/window/linux/clipboard.c",
            "lib/window/linux/decoration.c",
            "lib/window/linux/background_effect.c",

            "lib/window/linux/accessible.c",
        },
        .flags = flags.items,
    });
    // Link dependencies on the consumer; putting shared libraries into a static
    // archive makes the linker treat .so files as archive members.
    for (libraries) |library| {
        module.linkSystemLibrary(library, .{});
    }

    module.addIncludePath(b.path("lib/window/native"));
    module.addIncludePath(b.path("lib/window/linux"));
    for (protocol.include_dirs.items) |directory| {
        module.addIncludePath(directory.path);
    }

    // Keep protocol symbols and native mechanisms together in the window library.
    module.linkLibrary(b.addLibrary(.{ .name = "window-native", .linkage = .static, .root_module = protocol }));
    module.linkSystemLibrary("wayland-client", .{});
    module.addIncludePath(b.path("lib/window/vulkan"));
    module.linkSystemLibrary("vulkan", .{});
}
