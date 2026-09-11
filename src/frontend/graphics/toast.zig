//! Client-owned KGP rendering for notifications.
//!
//! Ownership: disposable client presentation state. Authority: the bounded
//! notification center. Budget: at most four 1.5 MiB RGBA images, at most 256
//! KiB of encoded image data per media pass, and placement-only updates while
//! animating. Any media failure removes every placement and leaves the cell
//! renderer fully functional.

const std = @import("std");
const PaletteType = @import("../ui/Palette.zig");
const Colors = @import("Colors.zig");
const ColorType = @import("telar-core").Color;
const GraphicsColor = @import("Color.zig");
const MetricsType = @import("Metrics.zig");
const SurfaceType = @import("Surface.zig");
const PixelRectangle = @import("PixelRectangle.zig");
const OutputPlacementType = @import("kitty_protocol").OutputPlacement;
const ToastRenderer = @import("ToastRenderer.zig");
const CenterType = @import("telar-client").Center;
const theme = @import("../ui/theme_support.zig");
const transition_duration_ns_module = @import("telar-client").transition_duration_ns;
const ThemeType = @import("telar-client").Theme;
const RectType = @import("telar-core").Rect;
const kitty_codec = @import("kitty_codec.zig");

pub const max_image_bytes: usize = 1536 * 1024;
pub const idle_after_ns: u64 = 250 * std.time.ns_per_ms;
const first_image_id: u32 = 0x80001000;
const first_placement_id: u32 = 0x80001100;
pub const toast_z_index: i32 = 1000;

pub fn resolveColors(palette: *const PaletteType) ?Colors {
    return .{
        .surface0 = rgb(palette.surface0) orelse return null,
        .text = rgb(palette.text) orelse return null,
        .subtext = rgb(palette.subtext0) orelse return null,
        .blue = rgb(palette.blue) orelse return null,
        .green = rgb(palette.green) orelse return null,
        .yellow = rgb(palette.yellow) orelse return null,
        .red = rgb(palette.red) orelse return null,
    };
}

fn rgb(color: ColorType) ?[3]u8 {
    return switch (color) {
        .rgb => |value| value,
        else => null,
    };
}

pub fn rasterColor(value: [3]u8) GraphicsColor {
    return .{ .red = value[0], .green = value[1], .blue = value[2] };
}

pub fn baseline(metrics: MetricsType, row_y: u32, row_height: u16) i32 {
    const spare = @as(i32, row_height) - @as(i32, @intCast(metrics.line_height));
    const centered_y: i32 = @intCast(row_y + @as(u32, @intCast(@max(0, @divTrunc(spare, 2)))));
    return centered_y + metrics.ascender;
}

pub fn fill(surface: SurfaceType, color: [4]u8) void {
    var index: usize = 0;
    while (index < surface.pixels.len) : (index += 4)
        @memcpy(surface.pixels[index..][0..4], &color);
}

pub fn fillRect(surface: SurfaceType, rectangle: PixelRectangle, color: GraphicsColor) void {
    const right = @min(surface.width, rectangle.x +| rectangle.width);
    const bottom = @min(surface.height, rectangle.y +| rectangle.height);
    var row = rectangle.y;
    while (row < bottom) : (row += 1) {
        var column = rectangle.x;
        while (column < right) : (column += 1) {
            const index = (@as(usize, row) * surface.width + column) * 4;
            surface.pixels[index..][0..4].* = .{ color.red, color.green, color.blue, color.alpha };
        }
    }
}

pub fn imageId(index: usize) u32 {
    return first_image_id + @as(u32, @intCast(index));
}

pub fn placementId(index: usize) u32 {
    return first_placement_id + @as(u32, @intCast(index));
}

pub fn optionalPlacementEql(a: ?OutputPlacementType, b: ?OutputPlacementType) bool {
    if (a == null or b == null) {
        return a == null and b == null;
    }
    return std.meta.eql(a.?, b.?);
}

test "terminal-derived palettes keep the cell fallback" {
    var renderer = ToastRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    _ = renderer.configure(.{ .support = .supported, .cell_width = 10, .cell_height = 20 });
    var center: CenterType = .{};
    _ = center.push(0, .{ .title = "Ready", .message = "Open result" });
    renderer.prepare(.{
        .area = .{ .w = 48, .h = 4 },
        .center = &center,
        .palette = &theme.builtin(.terminal).palette,
    });
    try std.testing.expect(!renderer.frame_usable);
    try std.testing.expect(!renderer.coversAll());
}

test "Nerd Font theme rasterizes the close icon into graphical toasts" {
    var renderer = ToastRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    try std.testing.expect(renderer.icons != null);
    _ = renderer.configure(.{ .support = .supported, .cell_width = 10, .cell_height = 20 });
    renderer.setMediaIdle(true);
    var center: CenterType = .{};
    _ = center.push(0, .{ .title = "Ready", .message = "Open result" });
    _ = center.advance(transition_duration_ns_module);
    renderer.prepare(.{
        .area = .{ .w = 48, .h = 4 },
        .center = &center,
        .palette = &theme.default_theme.palette,
        .icon_theme = .nerd_font,
    });
    try std.testing.expect(renderer.frame_usable);
    try std.testing.expectEqual(ThemeType.nerd_font, renderer.slots[0].key.?.icon_theme);
}

test "toast pixel cache is bounded independently of wire pacing" {
    try std.testing.expectEqual(@as(usize, 1536 * 1024), max_image_bytes);
}

test "large toast transmission is chunked across bounded media passes" {
    const Io = std.Io;
    var renderer = ToastRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    // These are the cell dimensions from the instrumented Ghostty session:
    // one 48x4-cell toast is 1,056x232 pixels, or 979,968 retained RGBA bytes.
    _ = renderer.configure(.{ .support = .supported, .cell_width = 22, .cell_height = 58 });
    renderer.setMediaIdle(true);
    var center: CenterType = .{};
    const id = center.push(0, .{
        .level = .success,
        .title = "Build complete",
        .message = "Open the result",
        .target = .{ .select_tab = @enumFromInt(7) },
    });
    _ = center.advance(transition_duration_ns_module);
    const area: RectType = .{ .x = 20, .y = 1, .w = 48, .h = 4 };
    renderer.prepare(.{ .area = area, .center = &center, .palette = &theme.default_theme.palette });
    try std.testing.expect(renderer.transmissionPending());
    try std.testing.expect(!renderer.coversAll());

    var first: Io.Writer.Allocating = .init(std.testing.allocator);
    defer first.deinit();
    _ = try renderer.write(&first.writer, true);
    try std.testing.expect(std.mem.indexOf(u8, first.written(), "a=t") != null);
    try std.testing.expect(first.written().len <= kitty_codec.transmission_budget_per_frame + 8192);
    try std.testing.expect(renderer.transmissionPending());
    var placed = std.mem.indexOf(u8, first.written(), "a=p") != null;
    var passes: usize = 1;
    while (renderer.transmissionPending()) {
        passes += 1;
        var chunk: Io.Writer.Allocating = .init(std.testing.allocator);
        defer chunk.deinit();
        // Once the first m=1 chunk is on the wire, the transfer must close
        // even if fresh host input disables starting another texture.
        _ = try renderer.write(&chunk.writer, false);
        try std.testing.expect(chunk.written().len <= kitty_codec.transmission_budget_per_frame + 8192);
        placed = placed or std.mem.indexOf(u8, chunk.written(), "a=p") != null;
    }
    try std.testing.expect(passes > 1);
    try std.testing.expect(renderer.coversAll());
    try std.testing.expect(placed);

    _ = center.dismiss(id, transition_duration_ns_module);
    _ = center.advance(transition_duration_ns_module + transition_duration_ns_module / 2);
    renderer.prepare(.{ .area = area, .center = &center, .palette = &theme.default_theme.palette });
    var moving: Io.Writer.Allocating = .init(std.testing.allocator);
    defer moving.deinit();
    _ = try renderer.write(&moving.writer, true);
    try std.testing.expect(std.mem.indexOf(u8, moving.written(), "a=t") == null);
    try std.testing.expect(std.mem.indexOf(u8, moving.written(), "a=p") != null);

    _ = center.advance(transition_duration_ns_module * 2);
    renderer.prepare(.{ .area = area, .center = &center, .palette = &theme.default_theme.palette });
    var removed: Io.Writer.Allocating = .init(std.testing.allocator);
    defer removed.deinit();
    _ = try renderer.write(&removed.writer, true);
    try std.testing.expect(std.mem.indexOf(u8, removed.written(), "a=d,d=I") != null);
}

test "rasterization waits for media idle and oversized cells fall back" {
    var renderer = ToastRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    _ = renderer.configure(.{ .support = .supported, .cell_width = 10, .cell_height = 20 });
    var center: CenterType = .{};
    _ = center.push(0, .{ .title = "Ready", .message = "Open result" });
    _ = center.advance(transition_duration_ns_module);
    const area: RectType = .{ .w = 48, .h = 4 };

    renderer.setMediaIdle(false);
    renderer.prepare(.{ .area = area, .center = &center, .palette = &theme.default_theme.palette });
    try std.testing.expect(renderer.render_deferred);
    try std.testing.expect(renderer.damaged());
    try std.testing.expect(!renderer.transmissionPending());

    renderer.setMediaIdle(true);
    renderer.prepare(.{ .area = area, .center = &center, .palette = &theme.default_theme.palette });
    try std.testing.expect(renderer.transmissionPending());

    _ = renderer.configure(.{ .support = .supported, .cell_width = 40, .cell_height = 80 });
    renderer.prepare(.{ .area = area, .center = &center, .palette = &theme.default_theme.palette });
    try std.testing.expect(!renderer.frame_usable);
    try std.testing.expect(!renderer.coversAll());
}
