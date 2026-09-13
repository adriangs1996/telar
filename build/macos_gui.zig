const std = @import("std");
const c_flags = @import("c_flags.zig");

/// Compile the native window adapter: `macos_gui.add(b, module, false)`.
pub fn add(b: *std.Build, module: *std.Build.Module, disable_coverage: bool) void {
    module.addCSourceFiles(.{
        .files = &.{
            "src/gui/macos/window.m",
            "src/gui/macos/TelarWindow.m",
            "src/gui/macos/TelarBackgroundBlur.m",
            "src/gui/macos/TelarView.m",
            "src/gui/macos/TelarWindowBackground.m",
            "src/gui/macos/TelarMetalRenderer.m",
            "src/gui/macos/TelarTextInputView.m",
            "src/gui/macos/TelarPointerInputView.m",
            "src/gui/macos/TelarPointerCursor.m",
            "src/gui/macos/font.m",
            "src/gui/macos/glyph_rasterizer.m",
        },
        .flags = c_flags.forCoverage(b, &.{ "-fobjc-arc", "-std=c23" }, disable_coverage),
    });
    module.linkFramework("AppKit", .{});
    module.linkFramework("CoreText", .{});
    module.linkFramework("CoreGraphics", .{});
    module.linkFramework("Metal", .{});
    module.linkFramework("QuartzCore", .{});
}
