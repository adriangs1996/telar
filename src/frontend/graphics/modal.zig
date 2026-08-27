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

const ui = core.ui;
const Io = std.Io;

pub const max_cache_bytes: usize = 512 * 1024;
const first_image_id: u32 = 0x80002000;
const first_placement_id: u32 = 0x80002100;
const z_index: i32 = 2001;
const supersample: u32 = 4;
const units_per_pixel: u32 = supersample * 2;
const asset_count = @typeInfo(AssetKind).@"enum".fields.len;
const placement_count = 8;

const AssetKind = enum(u2) {
    corners,
    horizontal,
    vertical,
};

const Asset = struct {
    pixels: []u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    dirty: bool = false,
    emitted: bool = false,
    transfer_offset: usize = 0,
};

const RenderKey = struct {
    target_width: u32,
    target_height: u32,
    cell_width: u16,
    cell_height: u16,
    border_width: u16,
    radius: u16,
    background: [3]u8,
    accent: [3]u8,
};

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    assets: [asset_count]Asset = @splat(.{}),
    supported: bool = false,
    cell_width: u16 = 0,
    cell_height: u16 = 0,
    key: ?RenderKey = null,
    desired_area: ?ui.Rect = null,
    emitted_area: ?ui.Rect = null,
    frame_usable: bool = false,
    partial: ?AssetKind = null,
    abort_pending: bool = false,

    pub fn init(gpa: std.mem.Allocator) Renderer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(renderer: *Renderer) void {
        for (&renderer.assets) |*asset| if (asset.pixels.len != 0)
            renderer.gpa.free(asset.pixels);
    }

    pub fn retainedBytes(renderer: *const Renderer) usize {
        var total: usize = 0;
        for (renderer.assets) |asset| total += asset.pixels.len;
        return total;
    }

    pub fn configure(
        renderer: *Renderer,
        support: kitty.Support,
        cell_width: u16,
        cell_height: u16,
    ) bool {
        const supported = support == .supported;
        if (renderer.supported == supported and renderer.cell_width == cell_width and
            renderer.cell_height == cell_height) return false;
        renderer.cancelPartial();
        renderer.supported = supported;
        renderer.cell_width = cell_width;
        renderer.cell_height = cell_height;
        renderer.key = null;
        if (!supported) {
            renderer.frame_usable = false;
            renderer.desired_area = null;
        }
        return true;
    }

    pub fn prepare(
        renderer: *Renderer,
        area: ui.Rect,
        palette: *const theme.Palette,
    ) void {
        renderer.frame_usable = renderer.supported and renderer.cell_width != 0 and
            renderer.cell_height != 0 and !area.isEmpty();
        const background = rgb(palette.surface0) orelse {
            renderer.hide();
            return;
        };
        const accent = rgb(palette.accent) orelse {
            renderer.hide();
            return;
        };
        if (!renderer.frame_usable) {
            renderer.hide();
            return;
        }

        const target_width = std.math.mul(u32, area.w, renderer.cell_width) catch {
            renderer.hide();
            return;
        };
        const target_height = std.math.mul(u32, area.h, renderer.cell_height) catch {
            renderer.hide();
            return;
        };
        const horizontal_width = target_width -| @as(u32, renderer.cell_width) * 2;
        const vertical_height = target_height -| @as(u32, renderer.cell_height) * 2;
        if (horizontal_width == 0 or vertical_height == 0) {
            renderer.hide();
            return;
        }
        const shortest = @min(renderer.cell_width, renderer.cell_height);
        const border_width = @max(@as(u16, 1), shortest / 10);
        const radius = @max(@as(u16, 1), @min(@as(u16, 12), shortest / 2));
        const key: RenderKey = .{
            .target_width = target_width,
            .target_height = target_height,
            .cell_width = renderer.cell_width,
            .cell_height = renderer.cell_height,
            .border_width = border_width,
            .radius = radius,
            .background = background,
            .accent = accent,
        };
        renderer.desired_area = area;
        if (renderer.key != null and std.meta.eql(renderer.key.?, key)) {
            for (&renderer.assets) |*asset| {
                if (!asset.emitted) asset.dirty = true;
            }
            return;
        }

        renderer.cancelPartial();
        const dimensions = [_][2]u32{
            .{ @as(u32, renderer.cell_width) * 4, renderer.cell_height },
            .{ horizontal_width, border_width },
            .{ border_width, vertical_height },
        };
        var total_bytes: usize = 0;
        for (dimensions) |size| {
            const pixels = std.math.mul(usize, size[0], size[1]) catch {
                renderer.hide();
                return;
            };
            const bytes = std.math.mul(usize, pixels, 4) catch {
                renderer.hide();
                return;
            };
            total_bytes = std.math.add(usize, total_bytes, bytes) catch {
                renderer.hide();
                return;
            };
        }
        if (total_bytes > max_cache_bytes) {
            renderer.hide();
            return;
        }
        for (&renderer.assets, dimensions) |*asset, size| {
            const byte_count = @as(usize, size[0]) * size[1] * 4;
            if (asset.pixels.len != byte_count) {
                const next = if (asset.pixels.len == 0)
                    renderer.gpa.alloc(u8, byte_count)
                else
                    renderer.gpa.realloc(asset.pixels, byte_count);
                asset.pixels = next catch {
                    renderer.key = null;
                    renderer.hide();
                    return;
                };
            }
            asset.width = size[0];
            asset.height = size[1];
        }
        renderCorners(renderer.assetFor(.corners), key);
        fill(renderer.assetFor(.horizontal).pixels, key.accent);
        fill(renderer.assetFor(.vertical).pixels, key.accent);
        renderer.key = key;
        for (&renderer.assets) |*asset| asset.dirty = true;
    }

    pub fn covers(renderer: *const Renderer, area: ui.Rect) bool {
        if (!renderer.frame_usable or renderer.partial != null or renderer.abort_pending or
            !optionalAreaEql(renderer.desired_area, area) or
            !optionalAreaEql(renderer.emitted_area, area)) return false;
        for (renderer.assets) |asset| if (asset.dirty or !asset.emitted) return false;
        return true;
    }

    pub fn damaged(renderer: *const Renderer) bool {
        if (renderer.abort_pending or renderer.partial != null or
            !optionalAreaEql(renderer.desired_area, renderer.emitted_area)) return true;
        if (!renderer.supported) {
            for (renderer.assets) |asset| if (asset.emitted) return true;
            return false;
        }
        if (renderer.frame_usable) for (renderer.assets) |asset| if (asset.dirty) return true;
        return false;
    }

    pub fn transferInProgress(renderer: *const Renderer) bool {
        return renderer.abort_pending or renderer.partial != null;
    }

    pub fn write(renderer: *Renderer, writer: *Io.Writer) Io.Writer.Error!usize {
        if (!renderer.damaged()) return 0;
        var written: usize = 0;
        if (renderer.abort_pending) {
            written += try kitty.writeTransmissionAbort(writer);
            renderer.abort_pending = false;
        }
        if (!renderer.supported) {
            for (&renderer.assets, 0..) |*asset, index| {
                if (asset.emitted)
                    written += try kitty.writeDeleteImage(writer, imageId(index));
                asset.emitted = false;
                asset.dirty = false;
                asset.transfer_offset = 0;
            }
            renderer.emitted_area = null;
            return written;
        }

        if (renderer.emitted_area != null and renderer.anyDirty()) {
            written += try renderer.deletePlacements(writer);
            renderer.emitted_area = null;
        }
        if (renderer.frame_usable) for (&renderer.assets, 0..) |*asset, index| {
            if (!asset.dirty) continue;
            if (asset.emitted) {
                written += try kitty.writeDeleteImage(writer, imageId(index));
                asset.emitted = false;
            }
            const progress = try kitty.writeTransmissionChunks(
                writer,
                imageId(index),
                .{
                    .key = .{ .image_id = imageId(index), .generation = 1 },
                    .format = .rgba,
                    .width = asset.width,
                    .height = asset.height,
                    .byte_len = asset.pixels.len,
                },
                asset.pixels,
                asset.transfer_offset,
                kitty.transmission_budget_per_frame,
                false,
            );
            written += progress.written;
            asset.transfer_offset = progress.offset;
            if (progress.offset != asset.pixels.len) {
                renderer.partial = @enumFromInt(index);
                return written;
            }
            asset.transfer_offset = 0;
            asset.dirty = false;
            asset.emitted = true;
            renderer.partial = null;
            return written;
        };

        if (!optionalAreaEql(renderer.desired_area, renderer.emitted_area)) {
            if (renderer.emitted_area != null)
                written += try renderer.deletePlacements(writer);
            const ready = renderer.allImagesReady();
            if (renderer.desired_area) |area| {
                if (ready) written += try renderer.writePlacements(writer, area);
            }
            renderer.emitted_area = if (ready) renderer.desired_area else null;
        }
        return written;
    }

    fn assetFor(renderer: *Renderer, kind: AssetKind) *Asset {
        return &renderer.assets[@intFromEnum(kind)];
    }

    fn anyDirty(renderer: *const Renderer) bool {
        for (renderer.assets) |asset| if (asset.dirty) return true;
        return false;
    }

    fn allImagesReady(renderer: *const Renderer) bool {
        if (!renderer.frame_usable) return false;
        for (renderer.assets) |asset| if (asset.dirty or !asset.emitted) return false;
        return true;
    }

    fn cancelPartial(renderer: *Renderer) void {
        const kind = renderer.partial orelse return;
        renderer.assetFor(kind).transfer_offset = 0;
        renderer.partial = null;
        renderer.abort_pending = true;
    }

    fn hide(renderer: *Renderer) void {
        renderer.cancelPartial();
        renderer.frame_usable = false;
        renderer.desired_area = null;
    }

    fn deletePlacements(renderer: *Renderer, writer: *Io.Writer) Io.Writer.Error!usize {
        _ = renderer;
        var written: usize = 0;
        for (0..placement_count) |index|
            written += try kitty.writeDeletePlacement(
                writer,
                placementImageId(index),
                placementId(index),
            );
        return written;
    }

    fn writePlacements(
        renderer: *const Renderer,
        writer: *Io.Writer,
        area: ui.Rect,
    ) Io.Writer.Error!usize {
        const key = renderer.key.?;
        const horizontal = renderer.assets[@intFromEnum(AssetKind.horizontal)];
        const vertical = renderer.assets[@intFromEnum(AssetKind.vertical)];
        const right = area.x + area.w - 1;
        const bottom = area.y + area.h - 1;
        var written: usize = 0;
        const corner_positions = [_][2]u16{
            .{ area.x, area.y },
            .{ right, area.y },
            .{ area.x, bottom },
            .{ right, bottom },
        };
        for (corner_positions, 0..) |position, index| {
            written += try kitty.writeUiPlacement(
                writer,
                imageId(@intFromEnum(AssetKind.corners)),
                placementId(index),
                .{
                    .column = position[0],
                    .row = position[1],
                    .offset_x = 0,
                    .offset_y = 0,
                    .source_x = @as(u32, @intCast(index)) * key.cell_width,
                    .source_y = 0,
                    .source_width = key.cell_width,
                    .source_height = key.cell_height,
                    .columns = 0,
                    .rows = 0,
                },
                z_index,
            );
        }
        written += try kitty.writeUiPlacement(writer, imageId(@intFromEnum(AssetKind.horizontal)), placementId(4), .{
            .column = area.x + 1,
            .row = area.y,
            .offset_x = 0,
            .offset_y = 0,
            .source_x = 0,
            .source_y = 0,
            .source_width = horizontal.width,
            .source_height = horizontal.height,
            .columns = 0,
            .rows = 0,
        }, z_index);
        written += try kitty.writeUiPlacement(writer, imageId(@intFromEnum(AssetKind.horizontal)), placementId(5), .{
            .column = area.x + 1,
            .row = bottom,
            .offset_x = 0,
            .offset_y = key.cell_height - key.border_width,
            .source_x = 0,
            .source_y = 0,
            .source_width = horizontal.width,
            .source_height = horizontal.height,
            .columns = 0,
            .rows = 0,
        }, z_index);
        written += try kitty.writeUiPlacement(writer, imageId(@intFromEnum(AssetKind.vertical)), placementId(6), .{
            .column = area.x,
            .row = area.y + 1,
            .offset_x = 0,
            .offset_y = 0,
            .source_x = 0,
            .source_y = 0,
            .source_width = vertical.width,
            .source_height = vertical.height,
            .columns = 0,
            .rows = 0,
        }, z_index);
        written += try kitty.writeUiPlacement(writer, imageId(@intFromEnum(AssetKind.vertical)), placementId(7), .{
            .column = right,
            .row = area.y + 1,
            .offset_x = key.cell_width - key.border_width,
            .offset_y = 0,
            .source_x = 0,
            .source_y = 0,
            .source_width = vertical.width,
            .source_height = vertical.height,
            .columns = 0,
            .rows = 0,
        }, z_index);
        return written;
    }
};

fn renderCorners(asset: *Asset, key: RenderKey) void {
    @memset(asset.pixels, 0);
    for (0..4) |corner| {
        const right = corner % 2 == 1;
        const bottom = corner >= 2;
        var y: u32 = 0;
        while (y < key.cell_height) : (y += 1) {
            var x: u32 = 0;
            while (x < key.cell_width) : (x += 1) {
                const destination_x = @as(u32, @intCast(corner)) * key.cell_width + x;
                renderCornerPixel(asset, destination_x, y, x, y, right, bottom, key);
            }
        }
    }
}

fn renderCornerPixel(
    asset: *Asset,
    destination_x: u32,
    destination_y: u32,
    local_x: u32,
    local_y: u32,
    right: bool,
    bottom: bool,
    key: RenderKey,
) void {
    const width_units = key.target_width * units_per_pixel;
    const height_units = key.target_height * units_per_pixel;
    const radius_units = @as(u32, key.radius) * units_per_pixel;
    const border_units = @as(u32, key.border_width) * units_per_pixel;
    var border_samples: u32 = 0;
    var background_samples: u32 = 0;
    for (0..supersample) |sample_y| {
        for (0..supersample) |sample_x| {
            const x = (if (right) key.target_width - key.cell_width else 0) * units_per_pixel +
                local_x * units_per_pixel + @as(u32, @intCast(sample_x * 2 + 1));
            const y = (if (bottom) key.target_height - key.cell_height else 0) * units_per_pixel +
                local_y * units_per_pixel + @as(u32, @intCast(sample_y * 2 + 1));
            if (!insideRoundedRectangle(x, y, width_units, height_units, radius_units)) continue;
            const in_inner = x >= border_units and y >= border_units and
                x + border_units < width_units and y + border_units < height_units and
                insideRoundedRectangle(
                    x - border_units,
                    y - border_units,
                    width_units - border_units * 2,
                    height_units - border_units * 2,
                    radius_units -| border_units,
                );
            if (in_inner)
                background_samples += 1
            else
                border_samples += 1;
        }
    }
    const painted = border_samples + background_samples;
    if (painted == 0) return;
    const index = (@as(usize, destination_y) * asset.width + destination_x) * 4;
    inline for (0..3) |channel| {
        asset.pixels[index + channel] = @intCast(
            (@as(u32, key.accent[channel]) * border_samples +
                @as(u32, key.background[channel]) * background_samples + painted / 2) /
                painted,
        );
    }
    asset.pixels[index + 3] = @intCast(
        (painted * 255 + supersample * supersample / 2) /
            (supersample * supersample),
    );
}

fn insideRoundedRectangle(x: u32, y: u32, width: u32, height: u32, radius: u32) bool {
    if (radius == 0) return true;
    if ((x >= radius and x <= width - radius) or
        (y >= radius and y <= height - radius)) return true;
    const center_x = if (x < radius) radius else width - radius;
    const center_y = if (y < radius) radius else height - radius;
    const delta_x = @as(i64, x) - center_x;
    const delta_y = @as(i64, y) - center_y;
    return delta_x * delta_x + delta_y * delta_y <= @as(i64, radius) * radius;
}

fn fill(pixels: []u8, color: [3]u8) void {
    var index: usize = 0;
    while (index < pixels.len) : (index += 4)
        pixels[index..][0..4].* = .{ color[0], color[1], color[2], 255 };
}

fn rgb(color: ui.Color) ?[3]u8 {
    return switch (color) {
        .rgb => |value| value,
        else => null,
    };
}

fn imageId(index: usize) u32 {
    return first_image_id + @as(u32, @intCast(index));
}

fn placementId(index: usize) u32 {
    return first_placement_id + @as(u32, @intCast(index));
}

fn placementImageId(index: usize) u32 {
    return imageId(if (index < 4) 0 else if (index < 6) 1 else 2);
}

fn optionalAreaEql(a: ?ui.Rect, b: ?ui.Rect) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.meta.eql(a.?, b.?);
}

test "rounded modal assets are exact-size bounded and transparent outside corners" {
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    _ = renderer.configure(.supported, 10, 20);
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

test "modal frame transmission ends in eight natural-size placements" {
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    _ = renderer.configure(.supported, 10, 20);
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
    _ = renderer.configure(.supported, 10, 20);
    const area: ui.Rect = .{ .x = 2, .y = 1, .w = 40, .h = 12 };
    renderer.prepare(area, &theme.default_theme.palette);

    var initial: Io.Writer.Allocating = .init(std.testing.allocator);
    defer initial.deinit();
    while (renderer.damaged()) _ = try renderer.write(&initial.writer);

    _ = renderer.configure(.supported, 11, 20);
    renderer.prepare(area, &theme.default_theme.palette);
    renderer.prepare(.{}, &theme.default_theme.palette);
    var closed: Io.Writer.Allocating = .init(std.testing.allocator);
    defer closed.deinit();
    _ = try renderer.write(&closed.writer);

    try std.testing.expect(!renderer.damaged());
    try std.testing.expectEqual(@as(usize, placement_count), std.mem.count(u8, closed.written(), "a=d,d=i"));
}
