const std = @import("std");
const RectType = @import("telar-core").Rect;
const SidebarProviderPlacement = @import("SidebarProviderPlacement.zig");
const SidebarContent = @import("SidebarContent.zig");
const CellSize = @import("CellSize.zig");
const kitty_sidebar = @import("kitty_sidebar.zig");
const SidebarFocus = @import("SidebarFocus.zig");
const rounded = @import("rounded_rectangle.zig");
const writeDeleteImage_module = @import("kitty_protocol").writeDeleteImage;
const kitty_codec = @import("kitty_codec.zig");
const writeDeletePlacement_module = @import("kitty_protocol").writeDeletePlacement;
/// Media assets for the hybrid sidebar. Cells retain the complete fallback,
/// hover, text, and hit targets; graphics add only the rounded focus edge and
/// official provider artwork.
const KittySidebarRenderer = @This();

const focused_card_id: u32 = 0x80000001;
const focused_card_placement_id: u32 = 0x80000010;
const provider_atlas_id: u32 = 0x80000003;
const first_provider_placement_id: u32 = 0x80000100;
const max_provider_placements = 64;
pub const provider_count = 3;
pub const provider_source_size = 256;
pub const provider_source_width = provider_count * provider_source_size;
const provider_raster_size = 64;
pub const provider_source_pixels: []const u8 = @import("assets").provider_marks_rgba;
// A flat rounded card needs little source resolution. This keeps its RGBA
// payload plus the provider atlas comfortably inside one media pass even
// after base64 expansion.
pub const max_focused_card_pixels = 16 * 1024;

comptime {
    std.debug.assert(provider_source_pixels.len == provider_source_width * provider_source_size * 4);
}

gpa: std.mem.Allocator,
focused_card_pixels: []u8 = &.{},
focused_card_width: u32 = 0,
focused_card_height: u32 = 0,
focused_card_color: [3]u8 = @splat(0),
focused_card: ?RectType = null,
emitted_focused_card: ?RectType = null,
focused_card_dirty: bool = false,
focused_card_emitted: bool = false,
provider_atlas: []u8 = &.{},
provider_slot_width: u32 = 0,
provider_slot_height: u32 = 0,
provider_atlas_width: u32 = 0,
provider_atlas_height: u32 = 0,
area: RectType = .{},
provider_marks: [max_provider_placements]SidebarProviderPlacement = undefined,
provider_mark_count: u8 = 0,
emitted_provider_mark_count: u8 = 0,
provider_dirty: bool = false,
placements_dirty: bool = false,
visible: bool = false,
emitted: bool = false,
provider_emitted: bool = false,

pub fn init(gpa: std.mem.Allocator) KittySidebarRenderer {
    return .{ .gpa = gpa };
}

pub fn deinit(renderer: *KittySidebarRenderer) void {
    if (renderer.focused_card_pixels.len != 0) {
        renderer.gpa.free(renderer.focused_card_pixels);
    }
    if (renderer.provider_atlas.len != 0) {
        renderer.gpa.free(renderer.provider_atlas);
    }
}

pub fn retainedBytes(renderer: *const KittySidebarRenderer) usize {
    return renderer.focused_card_pixels.len + renderer.provider_atlas.len;
}

/// Prepares sidebar graphics for one cell-layout frame.
/// For example: `try renderer.prepare(content, .{ .width = 10, .height = 20 })`.
pub fn prepare(renderer: *KittySidebarRenderer, content: SidebarContent, cell: CellSize) !void {
    if (content.provider_marks.len > max_provider_placements) {
        return error.TooManySidebarPlacements;
    }
    if (content.area.isEmpty() or cell.width == 0 or cell.height == 0) {
        renderer.visible = false;
        renderer.placements_dirty = renderer.emitted;
        return;
    }
    try renderer.prepareFocusedCard(content.focused_card, cell);
    const provider_scale = @max(@as(u32, 1), provider_raster_size / @as(u32, @min(cell.width, cell.height)));
    const provider_slot_width = std.math.mul(u32, cell.width, provider_scale) catch return error.SidebarTooLarge;
    const provider_slot_height = std.math.mul(u32, cell.height, provider_scale) catch return error.SidebarTooLarge;
    const provider_atlas_width = std.math.mul(u32, provider_count, provider_slot_width) catch return error.SidebarTooLarge;
    const provider_atlas_height = provider_slot_height;
    const provider_atlas_len = try kitty_sidebar.rgbaLength(provider_atlas_width, provider_atlas_height);
    const resized = renderer.provider_slot_width != provider_slot_width or
        renderer.provider_slot_height != provider_slot_height;
    if (resized) {
        const next_provider_atlas = try renderer.gpa.alloc(u8, provider_atlas_len);
        if (renderer.provider_atlas.len != 0) {
            renderer.gpa.free(renderer.provider_atlas);
        }
        renderer.provider_atlas = next_provider_atlas;
        renderer.provider_slot_width = provider_slot_width;
        renderer.provider_slot_height = provider_slot_height;
        renderer.provider_atlas_width = provider_atlas_width;
        renderer.provider_atlas_height = provider_atlas_height;
        kitty_sidebar.renderProviderAtlas(.{
            .destination = renderer.provider_atlas,
            .atlas = .{ .width = provider_atlas_width, .height = provider_atlas_height },
            .slot = .{ .width = provider_slot_width, .height = provider_slot_height },
        });
        renderer.provider_emitted = false;
        renderer.provider_dirty = content.provider_marks.len != 0;
        renderer.placements_dirty = true;
    }
    if (!renderer.visible) {
        renderer.provider_dirty = content.provider_marks.len != 0;
        renderer.placements_dirty = true;
    }
    if (!std.meta.eql(renderer.area, content.area)) {
        renderer.placements_dirty = true;
    }
    if (!kitty_sidebar.providerPlacementsEqual(renderer.provider_marks[0..renderer.provider_mark_count], content.provider_marks)) {
        @memcpy(renderer.provider_marks[0..content.provider_marks.len], content.provider_marks);
        renderer.provider_mark_count = @intCast(content.provider_marks.len);
        renderer.placements_dirty = true;
    }
    if (content.provider_marks.len != 0 and !renderer.provider_emitted) {
        renderer.provider_dirty = true;
    }
    renderer.area = content.area;
    renderer.visible = true;
}

fn prepareFocusedCard(renderer: *KittySidebarRenderer, focused: ?SidebarFocus, cell: CellSize) !void {
    const next_card = if (focused) |value| value.area else null;
    if (!std.meta.eql(renderer.focused_card, next_card)) {
        renderer.placements_dirty = true;
    }
    renderer.focused_card = next_card;
    const value = focused orelse {
        renderer.focused_card_dirty = false;
        return;
    };
    const target_width = std.math.mul(u32, value.area.w, cell.width) catch
        return error.SidebarTooLarge;
    const target_height = std.math.mul(u32, value.area.h, cell.height) catch
        return error.SidebarTooLarge;
    const raster_size = kitty_sidebar.fitWithinPixels(
        target_width,
        target_height,
        max_focused_card_pixels,
    );
    const changed = renderer.focused_card_width != raster_size.width or
        renderer.focused_card_height != raster_size.height or
        !std.mem.eql(u8, &renderer.focused_card_color, &value.color);
    if (!changed) {
        if (!renderer.focused_card_emitted) {
            renderer.focused_card_dirty = true;
        }
        return;
    }
    const byte_len = try kitty_sidebar.rgbaLength(raster_size.width, raster_size.height);
    const next_pixels = try renderer.gpa.alloc(u8, byte_len);
    errdefer renderer.gpa.free(next_pixels);
    const target_radius = @max(@as(u32, 2), @min(@as(u32, 12), cell.height / 3));
    const raster_radius = @max(
        @as(u32, 1),
        (@as(u64, target_radius) * raster_size.width + target_width / 2) / target_width,
    );
    rounded.render(.{
        .pixels = next_pixels,
        .shape = .{ .size = raster_size, .radius = @intCast(raster_radius) },
        .color = value.color,
    });
    if (renderer.focused_card_pixels.len != 0) {
        renderer.gpa.free(renderer.focused_card_pixels);
    }
    renderer.focused_card_pixels = next_pixels;
    renderer.focused_card_width = raster_size.width;
    renderer.focused_card_height = raster_size.height;
    renderer.focused_card_color = value.color;
    renderer.focused_card_dirty = true;
    renderer.placements_dirty = true;
}

pub fn damaged(renderer: *const KittySidebarRenderer) bool {
    return renderer.focused_card_dirty or renderer.provider_dirty or renderer.placements_dirty;
}

/// Emits pending sidebar images and placements. Geometry comes from what
/// `prepare` rasterized: taking live cell sizes here let a resize between
/// the two calls mismatch the placement against the pixels.
pub fn write(renderer: *KittySidebarRenderer, writer: *std.Io.Writer) std.Io.Writer.Error!usize {
    if (!renderer.damaged()) {
        return 0;
    }
    var written: usize = 0;
    if (!renderer.visible) {
        if (renderer.focused_card_emitted) {
            written += try writeDeleteImage_module(writer, focused_card_id);
        }
        if (renderer.provider_emitted) {
            written += try writeDeleteImage_module(writer, provider_atlas_id);
        }
        renderer.emitted = false;
        renderer.focused_card_emitted = false;
        renderer.emitted_focused_card = null;
        renderer.focused_card_dirty = false;
        renderer.provider_emitted = false;
        renderer.emitted_provider_mark_count = 0;
        renderer.provider_dirty = false;
        renderer.placements_dirty = false;
        return written;
    }
    if (renderer.focused_card_dirty) {
        written += try kitty_codec.writeTransmission(writer, .{
            .external_id = focused_card_id,
            .image = .{
                .key = .{ .image_id = focused_card_id, .generation = 1 },
                .format = .rgba,
                .width = renderer.focused_card_width,
                .height = renderer.focused_card_height,
                .byte_len = renderer.focused_card_pixels.len,
            },
            .pixels = renderer.focused_card_pixels,
        });
        renderer.focused_card_emitted = true;
    }
    if (renderer.provider_dirty) {
        written += try kitty_codec.writeTransmission(writer, .{
            .external_id = provider_atlas_id,
            .image = .{
                .key = .{ .image_id = provider_atlas_id, .generation = 1 },
                .format = .rgba,
                .width = renderer.provider_atlas_width,
                .height = renderer.provider_atlas_height,
                .byte_len = renderer.provider_atlas.len,
            },
            .pixels = renderer.provider_atlas,
        });
        renderer.provider_emitted = true;
    }
    if (renderer.placements_dirty) {
        if (renderer.emitted_focused_card != null) {
            written += try writeDeletePlacement_module(
                writer,
                focused_card_id,
                focused_card_placement_id,
            );
        }
        if (renderer.focused_card) |card| {
            if (renderer.focused_card_emitted) {
                written += try kitty_codec.writePlacement(writer, .{
                    .image_id = focused_card_id,
                    .placement_id = focused_card_placement_id,
                    .value = .{
                        .column = card.x,
                        .row = card.y,
                        .offset_x = 0,
                        .offset_y = 0,
                        .source_x = 0,
                        .source_y = 0,
                        .source_width = renderer.focused_card_width,
                        .source_height = renderer.focused_card_height,
                        .columns = card.w,
                        .rows = card.h,
                    },
                    .z = -9,
                });
            }
        }
        renderer.emitted_focused_card = renderer.focused_card;
        for (0..renderer.emitted_provider_mark_count) |index| written += try writeDeletePlacement_module(
            writer,
            provider_atlas_id,
            first_provider_placement_id + @as(u32, @intCast(index)),
        );
        for (renderer.provider_marks[0..renderer.provider_mark_count], 0..) |mark, index| {
            written += try kitty_codec.writePlacement(writer, .{
                .image_id = provider_atlas_id,
                .placement_id = first_provider_placement_id + @as(u32, @intCast(index)),
                .value = .{
                    .column = mark.area.x,
                    .row = mark.area.y,
                    .offset_x = 0,
                    .offset_y = 0,
                    .source_x = @as(u32, @intFromEnum(mark.provider)) * renderer.provider_slot_width,
                    .source_y = 0,
                    .source_width = renderer.provider_slot_width,
                    .source_height = renderer.provider_slot_height,
                    .columns = mark.area.w,
                    .rows = mark.area.h,
                },
                .z = -8,
            });
        }
        renderer.emitted_provider_mark_count = renderer.provider_mark_count;
    }
    renderer.focused_card_dirty = false;
    renderer.provider_dirty = false;
    renderer.placements_dirty = false;
    renderer.emitted = true;
    return written;
}
