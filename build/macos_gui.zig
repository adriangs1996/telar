const std = @import("std");
const macos_sdk = @import("macos_sdk.zig");

/// Native font and image helpers used by GUI frame preparation. The window
/// and its event loop are supplied exclusively by telar-window.
pub fn add(b: *std.Build, module: *std.Build.Module) void {
    module.addCSourceFiles(.{
        .files = &.{
            "src/gui/macos/font.m",
            "src/gui/macos/glyph_rasterizer.m",
        },
        .flags = &.{ "-fobjc-arc", "-std=c23" },
    });
    macos_sdk.addPaths(b, module);
    module.linkFramework("AppKit", .{});
    module.linkFramework("CoreText", .{});
    module.linkFramework("CoreGraphics", .{});
    module.linkFramework("Metal", .{});
    module.linkFramework("QuartzCore", .{});
}
