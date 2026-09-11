//! Sidebar media assets and rasterization, independent of the pane image store.

const std = @import("std");
const core = @import("telar-core");
const graphics = core.graphics;
pub const Io = std.Io;
const bitmap = @import("bitmap_support.zig");
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
pub const writeTransmission = codec.writeTransmission;
const writeSharedTransmission = codec.writeSharedTransmission;
const writeTransmissionAbort = codec.writeTransmissionAbort;
const PlacementCommand = codec.PlacementCommand;
pub const writePlacement = codec.writePlacement;
const writeUiPlacement = codec.writeUiPlacement;
pub const writeDeleteImage = codec.writeDeleteImage;
pub const writeDeletePlacement = codec.writeDeletePlacement;
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

pub const SidebarProviderPlacement = @import("SidebarProviderPlacement.zig");

pub const SidebarFocus = @import("SidebarFocus.zig");

pub const SidebarContent = @import("SidebarContent.zig");

pub const CellSize = @import("CellSize.zig");

pub const KittySidebarRenderer = @import("KittySidebarRenderer.zig");

pub fn providerPlacementsEqual(a: []const SidebarProviderPlacement, b: []const SidebarProviderPlacement) bool {
    if (a.len != b.len) {
        return false;
    }
    for (a, b) |left, right| if (!std.meta.eql(left, right)) return false;
    return true;
}

pub fn rgbaLength(width: u32, height: u32) !usize {
    const pixels = std.math.mul(usize, width, height) catch return error.SidebarTooLarge;
    return std.math.mul(usize, pixels, 4) catch return error.SidebarTooLarge;
}

pub const PixelSize = rounded.Size;

pub fn fitWithinPixels(width: u32, height: u32, max_pixels: usize) PixelSize {
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

const ProviderAtlasInput = @import("ProviderAtlasInput.zig");

pub fn renderProviderAtlas(input: ProviderAtlasInput) void {
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
