//! Graphics values shared by the runtime and disposable clients.
//!
//! This module deliberately contains no parser, allocator, PTY, or terminal
//! writer. It is the wire vocabulary between the owners of those resources.

const std = @import("std");

pub const max_images_per_pane: usize = 64;
pub const max_placements_per_pane: usize = 256;
pub const max_image_bytes_per_pane: usize = 64 * 1024 * 1024;
pub const max_image_bytes_global: usize = 256 * 1024 * 1024;
pub const max_image_bytes_per_screen: usize = max_image_bytes_per_pane / 2;
pub const max_encoded_chunk_bytes: usize = 64 * 1024;
pub const max_ipc_chunk_bytes: usize = 1024 * 1024;
pub const max_chunks_per_image: usize = 4096;
/// Darwin rejects POSIX shared memory names longer than PSHMNAMLEN (31)
/// bytes, so the wire and both processes agree on that bound.
pub const max_shm_name_bytes: usize = 31;

/// A validated POSIX shared memory object name crossing the runtime-client
/// boundary. The allowlist is exactly what Telar generates: a leading slash
/// followed by lowercase hex and dashes. Anything else is rejected before a
/// process calls `shm_open` with it.
pub const ShmName = struct {
    bytes: [max_shm_name_bytes + 1]u8 = undefined,
    len: u8 = 0,

    pub fn init(name: []const u8) error{InvalidShmName}!ShmName {
        if (name.len < 2 or name.len > max_shm_name_bytes)
            return error.InvalidShmName;
        if (name[0] != '/') return error.InvalidShmName;
        for (name[1..]) |byte| switch (byte) {
            'a'...'z', '0'...'9', '-' => {},
            else => return error.InvalidShmName,
        };
        var value: ShmName = .{ .len = @intCast(name.len) };
        @memcpy(value.bytes[0..name.len], name);
        value.bytes[name.len] = 0;
        return value;
    }

    pub fn slice(name: *const ShmName) []const u8 {
        return name.bytes[0..name.len];
    }

    pub fn sliceZ(name: *const ShmName) [:0]const u8 {
        return name.bytes[0..name.len :0];
    }
};

pub const Format = enum(u8) {
    rgb = 24,
    rgba = 32,

    pub fn bytesPerPixel(format: Format) usize {
        return switch (format) {
            .rgb => 3,
            .rgba => 4,
        };
    }
};

pub const ImageKey = struct {
    image_id: u32,
    generation: u64,
};

pub const Image = struct {
    key: ImageKey,
    format: Format,
    width: u32,
    height: u32,
    byte_len: u64,

    pub fn validate(image: Image, limit: usize) !usize {
        if (image.key.image_id == 0 or image.key.generation == 0)
            return error.InvalidImageIdentity;
        if (image.width == 0 or image.height == 0) return error.InvalidImageDimensions;
        const pixels = std.math.mul(usize, image.width, image.height) catch
            return error.ImageSizeOverflow;
        const expected = std.math.mul(usize, pixels, image.format.bytesPerPixel()) catch
            return error.ImageSizeOverflow;
        if (image.byte_len != expected) return error.InvalidImageLength;
        if (expected > limit) return error.ImageQuotaExceeded;
        return expected;
    }
};

/// A placement relative to a pane's cell grid. Source values are pixels in the
/// decoded image; offsets are pixels inside the anchor cell.
pub const Placement = struct {
    key: ImageKey,
    /// Runtime-unique within the pane. The child-facing placement ID remains
    /// separate because anonymous placements all have child ID zero.
    virtual_id: u64,
    placement_id: u32,
    x: i32,
    y: i32,
    source_x: u32 = 0,
    source_y: u32 = 0,
    source_width: u32 = 0,
    source_height: u32 = 0,
    columns: u32 = 0,
    rows: u32 = 0,
    offset_x: u32 = 0,
    offset_y: u32 = 0,
    z_index: i32 = 0,

    pub fn sourceRect(placement: Placement, image: Image) !Rect {
        if (placement.virtual_id == 0) return error.InvalidPlacementIdentity;
        if (!std.meta.eql(placement.key, image.key)) return error.PlacementImageMismatch;
        if (placement.source_x >= image.width or placement.source_y >= image.height)
            return error.InvalidSourceRectangle;
        const width = if (placement.source_width == 0)
            image.width - placement.source_x
        else
            placement.source_width;
        const height = if (placement.source_height == 0)
            image.height - placement.source_y
        else
            placement.source_height;
        const right = std.math.add(u32, placement.source_x, width) catch
            return error.InvalidSourceRectangle;
        const bottom = std.math.add(u32, placement.source_y, height) catch
            return error.InvalidSourceRectangle;
        if (width == 0 or height == 0 or right > image.width or bottom > image.height)
            return error.InvalidSourceRectangle;
        return .{
            .x = placement.source_x,
            .y = placement.source_y,
            .width = width,
            .height = height,
        };
    }
};

pub const Rect = struct {
    x: i64,
    y: i64,
    width: u64,
    height: u64,
};

pub const Clip = struct {
    destination: Rect,
    source: Rect,
};

/// Clips a scaled placement in pixel coordinates while preserving the source
/// rectangle. Integer division rounds inward, so no source pixel can escape
/// the destination boundary even for non-integral scaling ratios.
pub fn clipScaled(destination: Rect, source: Rect, bounds: Rect) ?Clip {
    if (destination.width == 0 or destination.height == 0 or
        source.width == 0 or source.height == 0 or
        bounds.width == 0 or bounds.height == 0) return null;

    const destination_right = addExtent(destination.x, destination.width) orelse return null;
    const destination_bottom = addExtent(destination.y, destination.height) orelse return null;
    const bounds_right = addExtent(bounds.x, bounds.width) orelse return null;
    const bounds_bottom = addExtent(bounds.y, bounds.height) orelse return null;
    const left = @max(destination.x, bounds.x);
    const top = @max(destination.y, bounds.y);
    const right = @min(destination_right, bounds_right);
    const bottom = @min(destination_bottom, bounds_bottom);
    if (left >= right or top >= bottom) return null;

    const clipped_left: u64 = @intCast(left - destination.x);
    const clipped_top: u64 = @intCast(top - destination.y);
    const clipped_right: u64 = @intCast(destination_right - right);
    const clipped_bottom: u64 = @intCast(destination_bottom - bottom);
    const source_left = scaleCeil(clipped_left, source.width, destination.width);
    const source_top = scaleCeil(clipped_top, source.height, destination.height);
    const source_right = scaleCeil(clipped_right, source.width, destination.width);
    const source_bottom = scaleCeil(clipped_bottom, source.height, destination.height);
    if (source_left + source_right >= source.width or
        source_top + source_bottom >= source.height) return null;

    return .{
        .destination = .{
            .x = left,
            .y = top,
            .width = @intCast(right - left),
            .height = @intCast(bottom - top),
        },
        .source = .{
            .x = source.x + @as(i64, @intCast(source_left)),
            .y = source.y + @as(i64, @intCast(source_top)),
            .width = source.width - source_left - source_right,
            .height = source.height - source_top - source_bottom,
        },
    };
}

fn addExtent(start: i64, extent: u64) ?i64 {
    const signed = std.math.cast(i64, extent) orelse return null;
    return std.math.add(i64, start, signed) catch null;
}

fn scaleCeil(value: u64, numerator: u64, denominator: u64) u64 {
    const product = std.math.mul(u128, value, numerator) catch unreachable;
    return @intCast((product + denominator - 1) / denominator);
}

test "image lengths reject mismatches overflow and quotas" {
    const image: Image = .{
        .key = .{ .image_id = 7, .generation = 9 },
        .format = .rgba,
        .width = 10,
        .height = 20,
        .byte_len = 800,
    };
    try std.testing.expectEqual(@as(usize, 800), try image.validate(800));
    var invalid = image;
    invalid.byte_len -= 1;
    try std.testing.expectError(error.InvalidImageLength, invalid.validate(800));
    try std.testing.expectError(error.ImageQuotaExceeded, image.validate(799));
    invalid = image;
    invalid.width = std.math.maxInt(u32);
    invalid.height = std.math.maxInt(u32);
    try std.testing.expectError(error.ImageSizeOverflow, invalid.validate(std.math.maxInt(usize)));
}

test "scaled clipping handles every edge" {
    const source: Rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 };
    const bounds: Rect = .{ .x = 0, .y = 0, .width = 80, .height = 80 };
    const clipped = clipScaled(
        .{ .x = -10, .y = -20, .width = 100, .height = 110 },
        source,
        bounds,
    ).?;
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 80, .height = 80 }, clipped.destination);
    try std.testing.expectEqual(Rect{ .x = 10, .y = 19, .width = 80, .height = 71 }, clipped.source);
}

test "scaled clipping maps each edge independently" {
    const source: Rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 };
    const bounds: Rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 };
    const cases = [_]struct { destination: Rect, expected_destination: Rect, expected_source: Rect }{
        .{
            .destination = .{ .x = -10, .y = 0, .width = 100, .height = 100 },
            .expected_destination = .{ .x = 0, .y = 0, .width = 90, .height = 100 },
            .expected_source = .{ .x = 10, .y = 0, .width = 90, .height = 100 },
        },
        .{
            .destination = .{ .x = 10, .y = 0, .width = 100, .height = 100 },
            .expected_destination = .{ .x = 10, .y = 0, .width = 90, .height = 100 },
            .expected_source = .{ .x = 0, .y = 0, .width = 90, .height = 100 },
        },
        .{
            .destination = .{ .x = 0, .y = -10, .width = 100, .height = 100 },
            .expected_destination = .{ .x = 0, .y = 0, .width = 100, .height = 90 },
            .expected_source = .{ .x = 0, .y = 10, .width = 100, .height = 90 },
        },
        .{
            .destination = .{ .x = 0, .y = 10, .width = 100, .height = 100 },
            .expected_destination = .{ .x = 0, .y = 10, .width = 100, .height = 90 },
            .expected_source = .{ .x = 0, .y = 0, .width = 100, .height = 90 },
        },
    };
    for (cases) |case| {
        const clipped = clipScaled(case.destination, source, bounds).?;
        try std.testing.expectEqual(case.expected_destination, clipped.destination);
        try std.testing.expectEqual(case.expected_source, clipped.source);
    }
}

test "scaled clipping rejects placements outside the pane" {
    try std.testing.expect(clipScaled(
        .{ .x = 20, .y = 20, .width = 5, .height = 5 },
        .{ .x = 0, .y = 0, .width = 5, .height = 5 },
        .{ .x = 0, .y = 0, .width = 10, .height = 10 },
    ) == null);
}

test "placement source rectangles are bounded by their image" {
    const image: Image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgba,
        .width = 100,
        .height = 80,
        .byte_len = 32_000,
    };
    const remaining = try (Placement{
        .key = image.key,
        .virtual_id = 1,
        .placement_id = 1,
        .x = 0,
        .y = 0,
        .source_x = 10,
        .source_y = 20,
    }).sourceRect(image);
    try std.testing.expectEqual(Rect{ .x = 10, .y = 20, .width = 90, .height = 60 }, remaining);
    try std.testing.expectError(error.InvalidSourceRectangle, (Placement{
        .key = image.key,
        .virtual_id = 2,
        .placement_id = 2,
        .x = 0,
        .y = 0,
        .source_x = 90,
        .source_width = 11,
    }).sourceRect(image));
}
