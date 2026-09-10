//! Sidebar media assets and rasterization, independent of the pane image store.

const std = @import("std");
const core = @import("telar-core");
const graphics = core.graphics;
const Io = std.Io;
const bitmap = @import("bitmap.zig");
const rounded = @import("rounded_rectangle.zig");
const codec = @import("kitty_codec.zig");
const transmission_budget_per_frame = codec.transmission_budget_per_frame;
const OutputPlacement = codec.OutputPlacement;
const ChunkProgress = codec.ChunkProgress;
const TransmissionChunks = codec.TransmissionChunks;
const PngTransmissionChunks = codec.PngTransmissionChunks;
const Transmission = codec.Transmission;
const SharedTransmission = codec.SharedTransmission;
const writeTransmissionChunks = codec.writeTransmissionChunks;
const writePngTransmissionChunks = codec.writePngTransmissionChunks;
const writeTransmission = codec.writeTransmission;
const writeSharedTransmission = codec.writeSharedTransmission;
const writeTransmissionAbort = codec.writeTransmissionAbort;
const PlacementCommand = codec.PlacementCommand;
const writePlacement = codec.writePlacement;
const writeUiPlacement = codec.writeUiPlacement;
const writeDeleteImage = codec.writeDeleteImage;
const writeDeletePlacement = codec.writeDeletePlacement;
const writeDeleteImageRange = codec.writeDeleteImageRange;

/// Column of the shipped provider-mark atlas. Only built-in agents have
/// artwork; a configured agent draws its manifest glyph as cells instead.
pub const SidebarProvider = enum {
    claude,
    codex,
    pi,

    /// ```zig
    /// const column = SidebarProvider.fromAgent(mark.provider) orelse continue;
    /// ```
    pub fn fromAgent(provider: core.schema.AgentProvider) ?SidebarProvider {
        return switch (provider) {
            .claude => .claude,
            .codex => .codex,
            .pi => .pi,
            else => null,
        };
    }
};

pub const SidebarProviderPlacement = struct {
    area: core.ui.Rect,
    provider: SidebarProvider,
};

pub const SidebarFocus = struct {
    area: core.ui.Rect,
    color: [3]u8,
};

pub const SidebarContent = struct {
    area: core.ui.Rect,
    focused_card: ?SidebarFocus,
    provider_marks: []const SidebarProviderPlacement,
};

pub const CellSize = struct {
    width: u16,
    height: u16,
};

/// Media assets for the hybrid sidebar. Cells retain the complete fallback,
/// hover, text, and hit targets; graphics add only the rounded focus edge and
/// official provider artwork.
pub const KittySidebarRenderer = struct {
    const focused_card_id: u32 = 0x80000001;
    const focused_card_placement_id: u32 = 0x80000010;
    const provider_atlas_id: u32 = 0x80000003;
    const first_provider_placement_id: u32 = 0x80000100;
    const max_provider_placements = 64;
    const provider_count = 3;
    const provider_source_size = 256;
    const provider_source_width = provider_count * provider_source_size;
    const provider_raster_size = 64;
    const provider_source_pixels: []const u8 = @embedFile("../assets/provider-marks-768x256.rgba");
    // A flat rounded card needs little source resolution. This keeps its RGBA
    // payload plus the provider atlas comfortably inside one media pass even
    // after base64 expansion.
    const max_focused_card_pixels = 16 * 1024;

    comptime {
        std.debug.assert(provider_source_pixels.len == provider_source_width * provider_source_size * 4);
    }

    gpa: std.mem.Allocator,
    focused_card_pixels: []u8 = &.{},
    focused_card_width: u32 = 0,
    focused_card_height: u32 = 0,
    focused_card_color: [3]u8 = @splat(0),
    focused_card: ?core.ui.Rect = null,
    emitted_focused_card: ?core.ui.Rect = null,
    focused_card_dirty: bool = false,
    focused_card_emitted: bool = false,
    provider_atlas: []u8 = &.{},
    provider_slot_width: u32 = 0,
    provider_slot_height: u32 = 0,
    provider_atlas_width: u32 = 0,
    provider_atlas_height: u32 = 0,
    area: core.ui.Rect = .{},
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
        const provider_atlas_len = try rgbaLength(provider_atlas_width, provider_atlas_height);
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
            renderProviderAtlas(.{
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
        if (!providerPlacementsEqual(renderer.provider_marks[0..renderer.provider_mark_count], content.provider_marks)) {
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
        const raster_size = fitWithinPixels(
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
        const byte_len = try rgbaLength(raster_size.width, raster_size.height);
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
    pub fn write(renderer: *KittySidebarRenderer, writer: *Io.Writer) Io.Writer.Error!usize {
        if (!renderer.damaged()) {
            return 0;
        }
        var written: usize = 0;
        if (!renderer.visible) {
            if (renderer.focused_card_emitted) {
                written += try writeDeleteImage(writer, focused_card_id);
            }
            if (renderer.provider_emitted) {
                written += try writeDeleteImage(writer, provider_atlas_id);
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
            written += try writeTransmission(writer, .{
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
            written += try writeTransmission(writer, .{
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
                written += try writeDeletePlacement(
                    writer,
                    focused_card_id,
                    focused_card_placement_id,
                );
            }
            if (renderer.focused_card) |card| {
                if (renderer.focused_card_emitted) {
                    written += try writePlacement(writer, .{
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
            for (0..renderer.emitted_provider_mark_count) |index| written += try writeDeletePlacement(
                writer,
                provider_atlas_id,
                first_provider_placement_id + @as(u32, @intCast(index)),
            );
            for (renderer.provider_marks[0..renderer.provider_mark_count], 0..) |mark, index| {
                written += try writePlacement(writer, .{
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
};

fn providerPlacementsEqual(a: []const SidebarProviderPlacement, b: []const SidebarProviderPlacement) bool {
    if (a.len != b.len) {
        return false;
    }
    for (a, b) |left, right| if (!std.meta.eql(left, right)) return false;
    return true;
}

fn rgbaLength(width: u32, height: u32) !usize {
    const pixels = std.math.mul(usize, width, height) catch return error.SidebarTooLarge;
    return std.math.mul(usize, pixels, 4) catch return error.SidebarTooLarge;
}

const PixelSize = rounded.Size;

fn fitWithinPixels(width: u32, height: u32, max_pixels: usize) PixelSize {
    if (@as(u64, width) * height <= max_pixels) {
        return .{ .width = width, .height = height };
    }
    const longest = @max(width, height);
    var lower: u32 = 1;
    var upper = longest;
    while (lower < upper) {
        const candidate = lower + (upper - lower + 1) / 2;
        const candidate_width = scaledPixelDimension(width, candidate, longest);
        const candidate_height = scaledPixelDimension(height, candidate, longest);
        if (@as(u64, candidate_width) * candidate_height <= max_pixels) {
            lower = candidate;
        } else {
            upper = candidate - 1;
        }
    }
    return .{
        .width = scaledPixelDimension(width, lower, longest),
        .height = scaledPixelDimension(height, lower, longest),
    };
}

fn scaledPixelDimension(value: u32, fitted_longest: u32, original_longest: u32) u32 {
    return @max(1, @as(u32, @intCast(
        (@as(u64, value) * fitted_longest + original_longest / 2) / original_longest,
    )));
}

fn clearRgba(pixels: []u8) void {
    @memset(pixels, 0);
}

const ProviderAtlasInput = struct {
    destination: []u8,
    atlas: PixelSize,
    slot: PixelSize,
};

fn renderProviderAtlas(input: ProviderAtlasInput) void {
    std.debug.assert(input.atlas.width == providerAtlasSourceCount() * input.slot.width);
    std.debug.assert(input.atlas.height == input.slot.height);
    clearRgba(input.destination);
    const icon_size = @min(input.slot.width, input.slot.height);
    const offset_x = (input.slot.width - icon_size) / 2;
    const offset_y = (input.slot.height - icon_size) / 2;
    var provider: u32 = 0;
    while (provider < providerAtlasSourceCount()) : (provider += 1) {
        const source: bitmap.Bitmap = .{
            .pixels = KittySidebarRenderer.provider_source_pixels,
            .stride = KittySidebarRenderer.provider_source_width,
            .origin_x = provider * KittySidebarRenderer.provider_source_size,
            .side = KittySidebarRenderer.provider_source_size,
        };
        var y: u32 = 0;
        while (y < icon_size) : (y += 1) {
            var x: u32 = 0;
            while (x < icon_size) : (x += 1) {
                const destination_x = provider * input.slot.width + offset_x + x;
                const destination_y = offset_y + y;
                const destination_index = (@as(usize, destination_y) * input.atlas.width + destination_x) * 4;
                input.destination[destination_index..][0..4].* = bitmap.sample(source, .{ .x = x, .y = y }, icon_size);
            }
        }
    }
}

fn providerAtlasSourceCount() u32 {
    return KittySidebarRenderer.provider_count;
}

test "sidebar provider marks preserve aspect ratio and reuse their atlas" {
    var renderer = KittySidebarRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    const area: core.ui.Rect = .{ .x = 1, .y = 1, .w = 8, .h = 8 };
    const providers = [_]SidebarProviderPlacement{
        .{
            .area = .{ .x = 3, .y = 5, .w = 2, .h = 2 },
            .provider = .claude,
        },
        .{
            .area = .{ .x = 3, .y = 7, .w = 2, .h = 2 },
            .provider = .codex,
        },
        .{
            .area = .{ .x = 3, .y = 9, .w = 2, .h = 2 },
            .provider = .pi,
        },
    };
    try renderer.prepare(.{ .area = area, .focused_card = null, .provider_marks = &providers }, .{ .width = 10, .height = 20 });
    try std.testing.expectEqual(@as(u32, 60), renderer.provider_slot_width);
    try std.testing.expectEqual(@as(u32, 120), renderer.provider_slot_height);
    var initial_buffer: [128 * 1024]u8 = undefined;
    var initial = Io.Writer.fixed(&initial_buffer);
    _ = try renderer.write(&initial);
    try std.testing.expect(std.mem.indexOf(u8, initial.buffered(), "a=t") != null);
    try std.testing.expect(std.mem.indexOf(u8, initial.buffered(), "x=60,y=0,w=60,h=120,c=2,r=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, initial.buffered(), "x=120,y=0,w=60,h=120,c=2,r=2") != null);
    try std.testing.expect(renderer.provider_emitted);

    try renderer.prepare(.{ .area = area, .focused_card = null, .provider_marks = &providers }, .{ .width = 10, .height = 20 });
    try std.testing.expect(!renderer.damaged());

    // A cell-size change while no agents are visible must still invalidate the
    // resident atlas before a later provider reuses it.
    try renderer.prepare(.{ .area = area, .focused_card = null, .provider_marks = &.{} }, .{ .width = 9, .height = 18 });
    var cleared_buffer: [4096]u8 = undefined;
    var cleared = Io.Writer.fixed(&cleared_buffer);
    _ = try renderer.write(&cleared);
    try std.testing.expect(!renderer.provider_emitted);

    try renderer.prepare(.{ .area = area, .focused_card = null, .provider_marks = &providers }, .{ .width = 9, .height = 18 });
    try std.testing.expect(renderer.provider_dirty);
    var resized_buffer: [128 * 1024]u8 = undefined;
    var resized = Io.Writer.fixed(&resized_buffer);
    _ = try renderer.write(&resized);
    try std.testing.expect(std.mem.indexOf(u8, resized.buffered(), "x=63,y=0,w=63,h=126,c=2,r=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, resized.buffered(), "x=126,y=0,w=63,h=126,c=2,r=2") != null);
}

test "sidebar focused card is rounded bounded and moves without retransmission" {
    var renderer = KittySidebarRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    const area: core.ui.Rect = .{ .x = 1, .y = 1, .w = 60, .h = 20 };
    const color = [3]u8{ 35, 35, 35 };
    const first: SidebarFocus = .{
        .area = .{ .x = 2, .y = 4, .w = 57, .h = 3 },
        .color = color,
    };
    try renderer.prepare(.{ .area = area, .focused_card = first, .provider_marks = &.{} }, .{ .width = 10, .height = 20 });
    try std.testing.expect(
        renderer.focused_card_pixels.len <= KittySidebarRenderer.max_focused_card_pixels * 4,
    );
    try std.testing.expect(renderer.focused_card_pixels[3] < 255);
    const center = ((@as(usize, renderer.focused_card_height) / 2 * renderer.focused_card_width +
        renderer.focused_card_width / 2) * 4);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 35, 35, 35, 255 },
        renderer.focused_card_pixels[center..][0..4],
    );

    var initial_buffer: [512 * 1024]u8 = undefined;
    var initial = Io.Writer.fixed(&initial_buffer);
    _ = try renderer.write(&initial);
    try std.testing.expect(std.mem.indexOf(u8, initial.buffered(), "a=t") != null);
    try std.testing.expect(std.mem.indexOf(u8, initial.buffered(), "a=p") != null);
    try std.testing.expect(std.mem.indexOf(u8, initial.buffered(), "z=-9") != null);

    const moved: SidebarFocus = .{
        .area = .{ .x = 2, .y = 8, .w = 57, .h = 3 },
        .color = color,
    };
    try renderer.prepare(.{ .area = area, .focused_card = moved, .provider_marks = &.{} }, .{ .width = 10, .height = 20 });
    var moved_buffer: [4096]u8 = undefined;
    var moved_writer = Io.Writer.fixed(&moved_buffer);
    _ = try renderer.write(&moved_writer);
    try std.testing.expect(std.mem.indexOf(u8, moved_writer.buffered(), "a=p") != null);
    try std.testing.expect(std.mem.indexOf(u8, moved_writer.buffered(), "a=t") == null);
}
