//! The smallest native client: one window that shows what the shared client
//! configuration resolved to. It exists to prove the paint contract and the
//! configuration path before any client port is implemented on it.
const std = @import("std");
const assets = @import("assets");
const Options = @import("telar-client").Options;
const Key = @import("telar-client").Key;
const native = @import("native/native.zig");
const cell_colors = @import("render/cell_colors.zig");
const Color = @import("render/Color.zig");
const QuadList = @import("render/QuadList.zig");
const GlyphAtlas = @import("text/GlyphAtlas.zig");
const Application = @This();

const title_points: f32 = 28;
const body_points: f32 = 15;
const margin_points: f32 = 32;
const label_width_points: f32 = 96;
const max_line_bytes = 256;

allocator: std.mem.Allocator,
options: Options,
quads: QuadList,
atlas: ?GlyphAtlas = null,
scale: f32 = 0,

pub fn init(allocator: std.mem.Allocator, options: Options) Application {
    return .{ .allocator = allocator, .options = options, .quads = QuadList.init(allocator) };
}

pub fn deinit(app: *Application) void {
    app.dropAtlas();
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

    const palette = &app.options.theme.palette;
    const text = cell_colors.resolve(palette.text, Color.white);
    const accent = cell_colors.resolve(palette.accent, Color.white);
    const subtext = cell_colors.resolve(palette.subtext0, text);
    const margin = margin_points * viewport.scale;
    const title_px: u16 = @intFromFloat(@round(title_points * viewport.scale));
    const body_px: u16 = @intFromFloat(@round(body_points * viewport.scale));
    const atlas = &app.atlas.?;

    try atlas.select(title_px);
    var y = margin + @as(f32, @floatFromInt(atlas.ascender()));
    _ = try atlas.place(.{ .text = "Telar", .x = margin, .y = y, .color = text, .pixel_height = title_px }, &app.quads);
    y += @as(f32, @floatFromInt(atlas.lineHeight())) * 1.5;

    try atlas.select(body_px);
    const body_line: f32 = @floatFromInt(atlas.lineHeight());
    var buffer: [max_line_bytes]u8 = undefined;
    const lines = [_]struct { label: []const u8, value: []const u8 }{
        .{ .label = "config", .value = app.options.config_path orelse "none, built-in defaults" },
        .{ .label = "profile", .value = app.options.profile orelse "default" },
        .{ .label = "theme", .value = app.options.theme.base.canonicalName() },
        .{ .label = "icons", .value = @tagName(app.options.icon_theme) },
        .{ .label = "prefix", .value = try formatKey(app.options.prefix, &buffer) },
    };
    for (lines) |line| {
        y += body_line;
        _ = try atlas.place(.{ .text = line.label, .x = margin, .y = y, .color = accent, .pixel_height = body_px }, &app.quads);
        _ = try atlas.place(.{ .text = line.value, .x = margin + label_width_points * viewport.scale, .y = y, .color = text, .pixel_height = body_px }, &app.quads);
    }

    y += body_line * 1.5;
    const counts = try std.fmt.bufPrint(&buffer, "{d} bindings, {d} bar callbacks, {d} plugins", .{
        app.options.bindings.len,
        if (app.options.lua_generation) |generation| generation.bar_callback_count else 0,
        if (app.options.plugin_registry) |registry| registry.count else 0,
    });
    _ = try atlas.place(.{ .text = counts, .x = margin, .y = y, .color = subtext, .pixel_height = body_px }, &app.quads);
}

fn formatKey(key: Key, buffer: []u8) ![]const u8 {
    var stream = std.Io.Writer.fixed(buffer);
    if (key.mods.ctrl) {
        try stream.writeAll("ctrl+");
    }

    if (key.mods.alt) {
        try stream.writeAll("alt+");
    }

    if (key.mods.shift) {
        try stream.writeAll("shift+");
    }

    switch (key.code) {
        .char => |char| try stream.writeAll(char.bytes[0..char.len]),
        inline else => |_, tag| try stream.writeAll(@tagName(tag)),
    }

    return stream.buffered();
}

fn ensureAtlas(app: *Application, scale: f32) !void {
    if (app.atlas != null and app.scale == scale) {
        return;
    }

    app.dropAtlas();
    app.atlas = try GlyphAtlas.init(app.allocator, .{
        .font = assets.jetbrains_mono,
        .pixel_height = @intFromFloat(@round(body_points * scale)),
    });
    app.scale = scale;
}

fn dropAtlas(app: *Application) void {
    if (app.atlas) |*atlas| {
        atlas.deinit();
        app.atlas = null;
    }
}

fn frame(app: *const Application) native.Frame {
    const quads = app.quads.items();
    const background = cell_colors.resolve(app.options.theme.palette.panel_bg, Color.black);
    return .{
        .quads = quads.ptr,
        .quad_count = @intCast(quads.len),
        .atlas = app.atlas.?.pixels.ptr,
        .atlas_side = GlyphAtlas.side,
        .atlas_version = app.atlas.?.version,
        .background = .{ background.r, background.g, background.b, 1 },
    };
}

test "a prefix chord formats as its modifiers and key" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("ctrl+s", try formatKey(.{ .code = .{ .char = .{ .bytes = .{ 's', 0, 0, 0 }, .len = 1 } }, .mods = .{ .ctrl = true } }, &buffer));
    try std.testing.expectEqualStrings("alt+enter", try formatKey(.{ .code = .enter, .mods = .{ .alt = true } }, &buffer));
}
