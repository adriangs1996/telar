//! Embedded Nerd Font icon rasterization and KGP placement.
//!
//! The widget frame supplies a bounded list of semantic marks. Preparation
//! deduplicates their glyph/color tuples and builds one atlas outside the
//! interactive path. Glyph slots are opaque over their cell background; the
//! telar mark keeps its own alpha, so it composes over any background the
//! host paints, including one Telar does not know. Cell fallbacks remain
//! underneath every placement.

const std = @import("std");
const MarkType = @import("../ui/Mark.zig");
const IconsSlot = @import("IconsSlot.zig");
const ui_icons = @import("../ui/icons.zig");
const IconType = @import("telar-client").Icon;
const Placement = @import("Placement.zig");
const RasterSize = @import("RasterSize.zig");
const RasterizerType = @import("Rasterizer.zig");
const AtlasInput = @import("AtlasInput.zig");
const SurfaceType = @import("Surface.zig");
const BitmapType = @import("Bitmap.zig");
const bitmap = @import("bitmap_support.zig");
const IconsRenderer = @import("IconsRenderer.zig");

pub const embedded_font: []const u8 = @import("assets").nerd_icons;

/// The telar mark is artwork rather than a font glyph, checked in at the
/// largest size a cell slot can use.
const mark_source: []const u8 = @import("assets").telar_mark_64_rgba;
const mark_source_side: u32 = 64;

comptime {
    std.debug.assert(mark_source.len == mark_source_side * mark_source_side * 4);
}

pub const image_id: u32 = 0x80000004;
pub const first_placement_id: u32 = 0x80000200;
pub const z_index: i32 = 10;
const max_pixel_dimension: u16 = 48;
pub const max_atlas_bytes: usize = 1536 * 1024;

const max_columns: u8 = 2;

pub fn slotFromMark(mark: MarkType) IconsSlot {
    return .{
        .icon = mark.icon,
        .foreground = mark.foreground,
        .background = mark.background,
        .columns = @intCast(std.math.clamp(mark.area.w, 1, max_columns)),
    };
}

pub fn widestSlot(slots: []const IconsSlot) u32 {
    var widest: u32 = 1;
    for (slots) |slot| {
        widest = @max(widest, slot.columns);
    }

    return widest;
}

pub fn ensureSlot(slots: *[ui_icons.max_marks]IconsSlot, count: *u8, wanted: IconsSlot) !u8 {
    if (findSlot(slots[0..count.*], wanted)) |slot| {
        return slot;
    }
    if (count.* == slots.len) {
        return error.TooManyIconSlots;
    }
    slots[count.*] = wanted;
    const added = count.*;
    count.* += 1;
    return added;
}

pub fn isWorkingIcon(icon: IconType) bool {
    return switch (icon) {
        .agent_working_0,
        .agent_working_1,
        .agent_working_2,
        .agent_working_3,
        => true,
        else => false,
    };
}

fn findSlot(slots: []const IconsSlot, wanted: IconsSlot) ?u8 {
    for (slots, 0..) |slot, index| {
        if (std.meta.eql(slot, wanted)) {
            return @intCast(index);
        }
    }
    return null;
}

pub fn slotsEqual(a: []const IconsSlot, b: []const IconsSlot) bool {
    if (a.len != b.len) {
        return false;
    }
    for (a, b) |left, right| if (!std.meta.eql(left, right)) return false;
    return true;
}

pub fn placementsEqual(a: []const Placement, b: []const Placement) bool {
    if (a.len != b.len) {
        return false;
    }
    for (a, b) |left, right| if (!std.meta.eql(left, right)) return false;
    return true;
}

pub fn rgbaLength(width: u32, height: u32) !usize {
    const pixels = std.math.mul(usize, width, height) catch
        return error.IconAtlasTooLarge;
    return std.math.mul(usize, pixels, 4) catch error.IconAtlasTooLarge;
}

pub fn fitCell(cell_width: u16, cell_height: u16) RasterSize {
    const longest = @max(cell_width, cell_height);
    if (longest <= max_pixel_dimension) {
        return .{
            .width = cell_width,
            .height = cell_height,
        };
    }
    return .{
        .width = scaledDimension(cell_width, longest),
        .height = scaledDimension(cell_height, longest),
    };
}

fn scaledDimension(value: u16, longest: u16) u16 {
    const numerator = @as(u32, value) * max_pixel_dimension + longest / 2;
    return @intCast(@max(1, numerator / longest));
}

// Every slot is drawn into one contiguous cell-sized surface, then copied
// into its atlas row. Rows are as wide as the widest slot; a narrower slot
// leaves the rest of its row transparent and never places it.
pub fn renderAtlas(text: *RasterizerType, atlas: AtlasInput) !void {
    const icon_size = @min(atlas.raster_size.width, atlas.raster_size.height);
    try text.setPixelHeight(icon_size);
    const metrics = text.metrics();
    const line_top = @divTrunc(
        @as(i32, atlas.raster_size.height) - @as(i32, @intCast(metrics.line_height)),
        2,
    );
    const baseline = line_top + metrics.ascender;
    const row_bytes = @as(usize, atlas.atlas_width) * atlas.raster_size.height * 4;
    var cell_pixels: [@as(usize, max_columns) * max_pixel_dimension * max_pixel_dimension * 4]u8 = undefined;
    for (atlas.slots, 0..) |slot, index| {
        const width = @as(u32, atlas.raster_size.width) * slot.columns;
        const surface: SurfaceType = .{
            .pixels = cell_pixels[0 .. @as(usize, width) * atlas.raster_size.height * 4],
            .width = width,
            .height = atlas.raster_size.height,
        };
        if (slot.icon == .telar_mark) {
            paintMark(surface);
        } else {
            fill(surface, slot.background);
            const advance = try text.drawText(.{
                .surface = surface,
                .origin = .{ .x = 0, .y = baseline },
                .text = slot.icon.nerdGlyph(),
                .color = .{
                    .red = slot.foreground[0],
                    .green = slot.foreground[1],
                    .blue = slot.foreground[2],
                },
                .max_width = width,
            });
            if (advance == 0) {
                return error.EmptyIconGlyph;
            }
        }

        const row = atlas.pixels[index * row_bytes ..][0..row_bytes];
        @memset(row, 0);
        var y: usize = 0;
        while (y < atlas.raster_size.height) : (y += 1) {
            const line = @as(usize, width) * 4;
            @memcpy(row[y * atlas.atlas_width * 4 ..][0..line], surface.pixels[y * line ..][0..line]);
        }
    }
}

/// Every destination pixel averages this many bilinear taps per axis, so a
/// 64 px source shrunk to a cell keeps its threads instead of skipping them.
const mark_taps: u32 = 4;

/// Paints the embedded mark into the slot with straight alpha: transparent
/// outside its square and its rounded corners, so the host terminal composes
/// it over whatever it paints behind the bar.
fn paintMark(surface: SurfaceType) void {
    @memset(surface.pixels, 0);
    const icon_size = @min(surface.width, surface.height);
    const offset_x = (surface.width - icon_size) / 2;
    const offset_y = (surface.height - icon_size) / 2;
    const source: BitmapType = .{ .pixels = mark_source, .stride = mark_source_side, .side = mark_source_side };
    const fine_size = icon_size * mark_taps;
    const tap_count: u32 = mark_taps * mark_taps;

    var y: u32 = 0;
    while (y < icon_size) : (y += 1) {
        var x: u32 = 0;
        while (x < icon_size) : (x += 1) {
            var premultiplied: [3]u32 = @splat(0);
            var alpha: u32 = 0;
            var tap_y: u32 = 0;
            while (tap_y < mark_taps) : (tap_y += 1) {
                var tap_x: u32 = 0;
                while (tap_x < mark_taps) : (tap_x += 1) {
                    const rgba = bitmap.sample(source, .{ .x = x * mark_taps + tap_x, .y = y * mark_taps + tap_y }, fine_size);
                    alpha += rgba[3];
                    inline for (0..3) |channel| {
                        premultiplied[channel] += @as(u32, rgba[channel]) * rgba[3];
                    }
                }
            }

            const index = (@as(usize, offset_y + y) * surface.width + offset_x + x) * 4;
            surface.pixels[index + 3] = @intCast((alpha + tap_count / 2) / tap_count);
            if (alpha == 0) {
                continue;
            }
            inline for (0..3) |channel| {
                surface.pixels[index + channel] = @intCast((premultiplied[channel] + alpha / 2) / alpha);
            }
        }
    }
}

fn fill(surface: SurfaceType, color: [3]u8) void {
    var pixel: usize = 0;
    while (pixel < surface.pixels.len) : (pixel += 4) {
        surface.pixels[pixel] = color[0];
        surface.pixels[pixel + 1] = color[1];
        surface.pixels[pixel + 2] = color[2];
        surface.pixels[pixel + 3] = 255;
    }
}

test "embedded subset rasterizes every configured Nerd Font icon" {
    var renderer = IconsRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    try std.testing.expect(renderer.text != null);
    _ = renderer.configure(.{ .support = .supported, .cell_width = 10, .cell_height = 20 });
    var marks: [std.meta.fields(IconType).len]MarkType = undefined;
    inline for (std.meta.fields(IconType), 0..) |field, index| {
        marks[index] = .{
            .area = .{ .x = @intCast(index), .w = 1, .h = 1 },
            .icon = @enumFromInt(field.value),
            .foreground = .{ 255, 255, 255 },
            .background = .{ 20, 20, 20 },
        };
    }
    try renderer.prepare(&marks);
    try std.testing.expectEqual(marks.len, renderer.slot_count);
    try std.testing.expect(renderer.atlas.len <= max_atlas_bytes);
    const slot_bytes = @as(usize, renderer.pixel_width) * renderer.pixel_height * 4;
    for (0..renderer.slot_count) |index| {
        const pixels = renderer.atlas[index * slot_bytes ..][0..slot_bytes];
        var visible = false;
        var pixel: usize = 0;
        while (pixel < pixels.len) : (pixel += 4) {
            if (!std.mem.eql(u8, pixels[pixel..][0..3], &.{ 20, 20, 20 })) {
                visible = true;
                break;
            }
        }
        try std.testing.expect(visible);
    }
}

test "the telar mark slot keeps its weft and stays transparent outside its square" {
    var renderer = IconsRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    _ = renderer.configure(.{ .support = .supported, .cell_width = 20, .cell_height = 40 });
    try renderer.prepare(&.{.{
        .area = .{ .w = 1, .h = 1 },
        .icon = .telar_mark,
        .foreground = .{ 0, 0, 0 },
        .background = .{ 0, 0, 0 },
    }});

    var peach = false;
    var index: usize = 0;
    while (index < renderer.atlas.len) : (index += 4) {
        const pixel = renderer.atlas[index..][0..4];
        if (pixel[3] > 200 and pixel[0] > 200 and pixel[0] > pixel[2] + 40) {
            peach = true;
            break;
        }
    }
    try std.testing.expect(peach);
    // The rows above the square icon are fully transparent.
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, renderer.atlas[0..4]);
    // The container's middle is opaque.
    const middle = ((@as(usize, renderer.pixel_height) / 2) * renderer.pixel_width + renderer.pixel_width / 2) * 4;
    try std.testing.expectEqual(@as(u8, 255), renderer.atlas[middle + 3]);
}

test "a two-column mark widens the atlas and places two cells" {
    var renderer = IconsRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    _ = renderer.configure(.{ .support = .supported, .cell_width = 10, .cell_height = 20 });
    try renderer.prepare(&.{
        .{ .area = .{ .x = 1, .w = 2, .h = 1 }, .icon = .telar_mark, .foreground = .{ 0, 0, 0 }, .background = .{ 0, 0, 0 } },
        .{ .area = .{ .x = 5, .w = 1, .h = 1 }, .icon = .cpu, .foreground = .{ 255, 255, 255 }, .background = .{ 20, 20, 20 } },
    });
    try std.testing.expectEqual(@as(u32, 20), renderer.atlas_width);
    try std.testing.expectEqual(@as(u32, 40), renderer.atlas_height);
    // The glyph slot keeps its right half transparent.
    const glyph_row = 20 * renderer.atlas_width * 4;
    try std.testing.expectEqual(@as(u8, 255), renderer.atlas[glyph_row + 3]);
    try std.testing.expectEqual(@as(u8, 0), renderer.atlas[glyph_row + 15 * 4 + 3]);

    var output: [65536]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    _ = try renderer.write(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "w=20,h=20,c=2,r=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "w=10,h=20,c=1,r=1") != null);
}

test "icon slots preserve the terminal cell aspect ratio" {
    try std.testing.expectEqual(RasterSize{ .width = 10, .height = 20 }, fitCell(10, 20));
    try std.testing.expectEqual(RasterSize{ .width = 24, .height = 48 }, fitCell(100, 200));
}

test "round Nerd Font icons remain square inside a tall cell" {
    var renderer = IconsRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    _ = renderer.configure(.{ .support = .supported, .cell_width = 20, .cell_height = 40 });
    try renderer.prepare(&.{.{
        .area = .{ .w = 1, .h = 1 },
        .icon = .agent_ready,
        .foreground = .{ 255, 255, 255 },
        .background = .{ 20, 20, 20 },
    }});

    var min_x: u16 = renderer.pixel_width;
    var min_y: u16 = renderer.pixel_height;
    var max_x: u16 = 0;
    var max_y: u16 = 0;
    var found = false;
    for (0..renderer.pixel_height) |y| {
        for (0..renderer.pixel_width) |x| {
            const index = (@as(usize, y) * renderer.pixel_width + x) * 4;
            if (std.mem.eql(u8, renderer.atlas[index..][0..3], &.{ 20, 20, 20 })) {
                continue;
            }
            found = true;
            min_x = @min(min_x, @as(u16, @intCast(x)));
            min_y = @min(min_y, @as(u16, @intCast(y)));
            max_x = @max(max_x, @as(u16, @intCast(x)));
            max_y = @max(max_y, @as(u16, @intCast(y)));
        }
    }
    try std.testing.expect(found);
    const width = max_x - min_x + 1;
    const height = max_y - min_y + 1;
    try std.testing.expect(@abs(@as(i32, width) - @as(i32, height)) <= 2);
}

test "icon atlas is transmitted before its placements" {
    var renderer = IconsRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    _ = renderer.configure(.{ .support = .supported, .cell_width = 10, .cell_height = 20 });
    try renderer.prepare(&.{.{
        .area = .{ .x = 2, .y = 3, .w = 1, .h = 1 },
        .icon = .cpu,
        .foreground = .{ 255, 255, 255 },
        .background = .{ 20, 20, 20 },
    }});

    var output: [16384]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    _ = try renderer.write(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "a=t") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "a=p") != null);
    try std.testing.expect(!renderer.damaged());
}

test "working animation changes placements without retransmitting the atlas" {
    var renderer = IconsRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    _ = renderer.configure(.{ .support = .supported, .cell_width = 10, .cell_height = 20 });
    const style = MarkType{
        .area = .{ .x = 2, .y = 3, .w = 1, .h = 1 },
        .icon = .agent_working_0,
        .foreground = .{ 255, 255, 255 },
        .background = .{ 20, 20, 20 },
    };
    try renderer.prepare(&.{style});
    var output: [65536]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    _ = try renderer.write(&writer);
    try std.testing.expect(!renderer.damaged());

    var next = style;
    next.icon = .agent_working_1;
    try renderer.prepare(&.{next});
    try std.testing.expect(!renderer.image_dirty);
    try std.testing.expect(renderer.placements_dirty);
}

test "unsupported terminals keep the renderer empty" {
    var renderer = IconsRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    _ = renderer.configure(.{ .support = .unsupported, .cell_width = 10, .cell_height = 20 });
    try renderer.prepare(&.{.{
        .area = .{ .w = 1, .h = 1 },
        .icon = .cpu,
        .foreground = .{ 255, 255, 255 },
        .background = .{ 20, 20, 20 },
    }});
    try std.testing.expect(!renderer.damaged());
}
