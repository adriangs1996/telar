//! The smallest native client: one window, one line of text. It exists to
//! prove the paint contract before any client port is implemented on it.
const std = @import("std");
const assets = @import("assets");
const native = @import("macos/native.zig");
const Color = @import("render/Color.zig");
const QuadList = @import("render/QuadList.zig");
const GlyphAtlas = @import("text/GlyphAtlas.zig");
const Application = @This();

const font_points: f32 = 28;
const margin_points: f32 = 32;
const background = Color.rgb(0x1e, 0x1e, 0x2e);
const foreground = Color.rgb(0xcd, 0xd6, 0xf4);

allocator: std.mem.Allocator,
quads: QuadList,
atlas: ?GlyphAtlas = null,
scale: f32 = 0,

pub fn init(allocator: std.mem.Allocator) Application {
    return .{ .allocator = allocator, .quads = QuadList.init(allocator) };
}

pub fn deinit(app: *Application) void {
    if (app.atlas) |*atlas| {
        atlas.deinit();
    }

    app.quads.deinit();
    app.* = undefined;
}

/// Opens the window and blocks until it closes.
/// Example: `try app.run("Telar");`
pub fn run(app: *Application, title: [*:0]const u8) !void {
    if (native.telar_gui_run(title, app, render) != 0) {
        return error.NativeWindowFailed;
    }
}

fn render(context: ?*anyopaque, viewport: native.Viewport, out: *native.Frame) callconv(.c) void {
    const app: *Application = @ptrCast(@alignCast(context.?));
    app.paint(viewport) catch |err| {
        std.log.err("paint failed: {s}", .{@errorName(err)});
        app.quads.clear();
    };

    out.* = app.frame();
}

fn paint(app: *Application, viewport: native.Viewport) !void {
    try app.ensureAtlas(viewport.scale);
    app.quads.clear();

    const atlas = &app.atlas.?;
    const margin = margin_points * viewport.scale;
    _ = try atlas.place(.{
        .text = "Telar",
        .x = margin,
        .y = margin + @as(f32, @floatFromInt(atlas.ascender())),
        .color = foreground,
    }, &app.quads);
}

fn ensureAtlas(app: *Application, scale: f32) !void {
    if (app.atlas != null and app.scale == scale) {
        return;
    }

    if (app.atlas) |*atlas| {
        atlas.deinit();
        app.atlas = null;
    }

    app.atlas = try GlyphAtlas.init(app.allocator, .{
        .font = assets.jetbrains_mono,
        .pixel_height = @intFromFloat(@round(font_points * scale)),
    });
    app.scale = scale;
}

fn frame(app: *const Application) native.Frame {
    const quads = app.quads.items();
    const atlas = &app.atlas.?;
    return .{
        .quads = quads.ptr,
        .quad_count = @intCast(quads.len),
        .atlas = atlas.pixels.ptr,
        .atlas_side = GlyphAtlas.side,
        .atlas_version = atlas.version,
        .background = .{ background.r, background.g, background.b, 1 },
    };
}
