//! Pixel-aligned KGP frame for client-owned modals.
//!
//! Three bounded images hold four exact-size corner cells, one horizontal
//! line, and one vertical line. Eight natural-size placements assemble them
//! without scaling, so the border keeps one physical thickness on every side.
//! Modal text and the rectangular body stay in the cell buffer.

const std = @import("std");
const core = @import("telar-core");
const kitty = @import("kitty.zig");
const theme = @import("../ui/root.zig").theme;

pub const ui = core.ui;
pub const Io = std.Io;

pub const max_cache_bytes: usize = 512 * 1024;
const first_image_id: u32 = 0x80002000;
const first_placement_id: u32 = 0x80002100;
pub const z_index: i32 = 2001;
const supersample: u32 = 4;
const units_per_pixel: u32 = supersample * 2;
pub const asset_count = @typeInfo(AssetKind).@"enum".fields.len;
pub const placement_count = 8;

pub const AssetKind = enum(u2) {
    corners,
    horizontal,
    vertical,
};

const Asset = @import("Asset.zig");

const RenderKey = @import("ModalRenderKey.zig");

pub const Renderer = @import("ModalRenderer.zig");

pub fn renderCorners(asset: *Asset, key: RenderKey) void {
    @memset(asset.pixels, 0);
    for (0..4) |corner| {
        const right = corner % 2 == 1;
        const bottom = corner >= 2;
        var y: u32 = 0;
        while (y < key.cell_height) : (y += 1) {
            var x: u32 = 0;
            while (x < key.cell_width) : (x += 1) {
                const destination_x = @as(u32, @intCast(corner)) * key.cell_width + x;
                renderCornerPixel(asset, .{
                    .destination = .{ .x = destination_x, .y = y },
                    .local = .{ .x = x, .y = y },
                    .right = right,
                    .bottom = bottom,
                    .key = key,
                });
            }
        }
    }
}

const PixelPoint = @import("PixelPoint.zig");

const RoundedRectangle = @import("RoundedRectangle.zig");

const CornerPixel = @import("CornerPixel.zig");

fn renderCornerPixel(asset: *Asset, pixel: CornerPixel) void {
    const width_units = pixel.key.target_width * units_per_pixel;
    const height_units = pixel.key.target_height * units_per_pixel;
    const radius_units = @as(u32, pixel.key.radius) * units_per_pixel;
    const border_units = @as(u32, pixel.key.border_width) * units_per_pixel;
    const outer: RoundedRectangle = .{ .width = width_units, .height = height_units, .radius = radius_units };
    const inner: RoundedRectangle = .{
        .width = width_units -| border_units * 2,
        .height = height_units -| border_units * 2,
        .radius = radius_units -| border_units,
    };
    var border_samples: u32 = 0;
    var background_samples: u32 = 0;
    for (0..supersample) |sample_y| {
        for (0..supersample) |sample_x| {
            const point: PixelPoint = .{
                .x = (if (pixel.right) pixel.key.target_width - pixel.key.cell_width else 0) * units_per_pixel +
                    pixel.local.x * units_per_pixel + @as(u32, @intCast(sample_x * 2 + 1)),
                .y = (if (pixel.bottom) pixel.key.target_height - pixel.key.cell_height else 0) * units_per_pixel +
                    pixel.local.y * units_per_pixel + @as(u32, @intCast(sample_y * 2 + 1)),
            };
            if (!insideRoundedRectangle(point, outer)) {
                continue;
            }
            const in_inner = point.x >= border_units and point.y >= border_units and
                point.x + border_units < width_units and point.y + border_units < height_units and
                insideRoundedRectangle(.{ .x = point.x - border_units, .y = point.y - border_units }, inner);
            if (in_inner) {
                background_samples += 1;
            } else {
                border_samples += 1;
            }
        }
    }
    const painted = border_samples + background_samples;
    if (painted == 0) {
        return;
    }
    const index = (@as(usize, pixel.destination.y) * asset.width + pixel.destination.x) * 4;
    inline for (0..3) |channel| {
        asset.pixels[index + channel] = @intCast(
            (@as(u32, pixel.key.accent[channel]) * border_samples +
                @as(u32, pixel.key.background[channel]) * background_samples + painted / 2) /
                painted,
        );
    }
    asset.pixels[index + 3] = @intCast(
        (painted * 255 + supersample * supersample / 2) /
            (supersample * supersample),
    );
}

fn insideRoundedRectangle(point: PixelPoint, rectangle: RoundedRectangle) bool {
    if (rectangle.radius == 0) {
        return true;
    }
    if ((point.x >= rectangle.radius and point.x <= rectangle.width - rectangle.radius) or
        (point.y >= rectangle.radius and point.y <= rectangle.height - rectangle.radius))
    {
        return true;
    }
    const center_x = if (point.x < rectangle.radius) rectangle.radius else rectangle.width - rectangle.radius;
    const center_y = if (point.y < rectangle.radius) rectangle.radius else rectangle.height - rectangle.radius;
    const delta_x = @as(i64, point.x) - center_x;
    const delta_y = @as(i64, point.y) - center_y;
    return delta_x * delta_x + delta_y * delta_y <= @as(i64, rectangle.radius) * rectangle.radius;
}

pub fn fill(pixels: []u8, color: [3]u8) void {
    var index: usize = 0;
    while (index < pixels.len) : (index += 4)
        pixels[index..][0..4].* = .{ color[0], color[1], color[2], 255 };
}

pub fn rgb(color: ui.Color) ?[3]u8 {
    return switch (color) {
        .rgb => |value| value,
        else => null,
    };
}

pub fn imageId(index: usize) u32 {
    return first_image_id + @as(u32, @intCast(index));
}

pub fn placementId(index: usize) u32 {
    return first_placement_id + @as(u32, @intCast(index));
}

pub fn placementImageId(index: usize) u32 {
    return imageId(if (index < 4) 0 else if (index < 6) 1 else 2);
}

pub fn optionalAreaEql(a: ?ui.Rect, b: ?ui.Rect) bool {
    if (a == null or b == null) {
        return a == null and b == null;
    }
    return std.meta.eql(a.?, b.?);
}

test "rounded modal assets are exact-size bounded and transparent outside corners" {
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    _ = renderer.configure(.{ .support = .supported, .cell_width = 10, .cell_height = 20 });
    renderer.prepare(.{ .x = 2, .y = 1, .w = 80, .h = 28 }, &theme.default_theme.palette);

    try std.testing.expect(renderer.frame_usable);
    try std.testing.expect(renderer.retainedBytes() <= max_cache_bytes);
    const corners = renderer.assetFor(.corners);
    try std.testing.expectEqual(@as(u32, 40), corners.width);
    try std.testing.expectEqual(@as(u32, 20), corners.height);
    try std.testing.expect(corners.pixels[3] < 255);
    const top_right_alpha = corners.pixels[((2 * 10 - 1) * 4) + 3];
    const bottom_left_alpha = corners.pixels[((19 * corners.width + 2 * 10) * 4) + 3];
    const bottom_right_alpha = corners.pixels[((20 * corners.width - 1) * 4) + 3];
    try std.testing.expectEqual(corners.pixels[3], top_right_alpha);
    try std.testing.expectEqual(corners.pixels[3], bottom_left_alpha);
    try std.testing.expectEqual(corners.pixels[3], bottom_right_alpha);
    try std.testing.expectEqual(@as(u8, 255), corners.pixels[((10 - 1) * 4) + 3]);
    try std.testing.expectEqual(@as(u8, 255), corners.pixels[((19 * corners.width) * 4) + 3]);
    try std.testing.expectEqual(@as(u8, 255), renderer.assetFor(.horizontal).pixels[3]);
    try std.testing.expectEqual(@as(u8, 255), renderer.assetFor(.vertical).pixels[3]);
}

test "modal assets use the same background as the client chrome" {
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    _ = renderer.configure(.{ .support = .supported, .cell_width = 10, .cell_height = 20 });
    var palette = theme.default_theme.palette;
    palette.panel_bg = .{ .rgb = .{ 1, 2, 3 } };
    palette.surface0 = .{ .rgb = .{ 4, 5, 6 } };

    renderer.prepare(.{ .x = 2, .y = 1, .w = 40, .h = 12 }, &palette);

    try std.testing.expectEqual([3]u8{ 1, 2, 3 }, renderer.key.?.background);
}

test "modal frame transmission ends in eight natural-size placements" {
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    _ = renderer.configure(.{ .support = .supported, .cell_width = 10, .cell_height = 20 });
    const area: ui.Rect = .{ .x = 2, .y = 1, .w = 40, .h = 12 };
    renderer.prepare(area, &theme.default_theme.palette);

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    while (renderer.damaged()) _ = try renderer.write(&output.writer);

    try std.testing.expect(renderer.covers(area));
    try std.testing.expectEqual(@as(usize, placement_count), std.mem.count(u8, output.written(), "z=2001"));
    try std.testing.expectEqual(@as(usize, placement_count), std.mem.count(u8, output.written(), "c=0,r=0"));
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b[2;4H") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b[13;4H") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b[3;3H") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b[3;42H") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output.written(), "X=0,Y=19,z=2001"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output.written(), "X=9,Y=0,z=2001"));
}

test "closing a stale modal frame leaves no media work behind" {
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    _ = renderer.configure(.{ .support = .supported, .cell_width = 10, .cell_height = 20 });
    const area: ui.Rect = .{ .x = 2, .y = 1, .w = 40, .h = 12 };
    renderer.prepare(area, &theme.default_theme.palette);

    var initial: Io.Writer.Allocating = .init(std.testing.allocator);
    defer initial.deinit();
    while (renderer.damaged()) _ = try renderer.write(&initial.writer);

    _ = renderer.configure(.{ .support = .supported, .cell_width = 11, .cell_height = 20 });
    renderer.prepare(area, &theme.default_theme.palette);
    renderer.prepare(.{}, &theme.default_theme.palette);
    var closed: Io.Writer.Allocating = .init(std.testing.allocator);
    defer closed.deinit();
    _ = try renderer.write(&closed.writer);

    try std.testing.expect(!renderer.damaged());
    try std.testing.expectEqual(@as(usize, placement_count), std.mem.count(u8, closed.written(), "a=d,d=i"));
}
