//! Graphics values shared by the runtime and disposable clients.
//!
//! This module deliberately contains no parser, allocator, PTY, or terminal
//! writer. It is the wire vocabulary between the owners of those resources.

const Rect = @import("Rect.zig");
const std = @import("std");

pub const max_images_per_pane: usize = 64;
pub const max_placements_per_pane: usize = 256;
/// The quotas must admit one full-pane RGBA frame on the largest display a
/// pane can cover: a 6K panel is 6016x3384x4 = 78 MiB. The per-screen cap
/// holds one such frame; the pane cap holds its resident copy, the incoming
/// replacement being loaded, and one frozen client transfer at once. A pane
/// that cannot ingest its own full-size frame turns latest-wins into a
/// permanently stale image, which reads as a frozen or black pane.
pub const max_image_bytes_per_pane: usize = 256 * 1024 * 1024;
pub const max_image_bytes_global: usize = 512 * 1024 * 1024;
pub const max_image_bytes_per_screen: usize = max_image_bytes_per_pane / 2;
pub const max_encoded_chunk_bytes: usize = 64 * 1024;
pub const max_ipc_chunk_bytes: usize = 1024 * 1024;
/// Image bytes one Kitty chunk carries when a child follows the protocol's
/// advice of 4096 base64 bytes a chunk.
const recommended_chunk_image_bytes: usize = 3072;
/// Chunks one image upload may span: enough for an image the size of a
/// screen's quota sent in recommended chunks, so the byte quota is the
/// bound a real upload meets.
pub const max_chunks_per_image: usize = max_image_bytes_per_screen / recommended_chunk_image_bytes;
/// Darwin rejects POSIX shared memory names longer than PSHMNAMLEN (31)
/// bytes, so the wire and both processes agree on that bound.
pub const max_shm_name_bytes: usize = 31;

/// Clips a scaled placement in pixel coordinates while preserving the source
/// rectangle. Integer division rounds inward, so no source pixel can escape
/// the destination boundary even for non-integral scaling ratios.
pub fn clipScaled(destination: Rect, source: Rect, bounds: Rect) ?Clip {
    if (destination.width == 0 or destination.height == 0 or
        source.width == 0 or source.height == 0 or
        bounds.width == 0 or bounds.height == 0)
    {
        return null;
    }

    const destination_right = addExtent(destination.x, destination.width) orelse return null;
    const destination_bottom = addExtent(destination.y, destination.height) orelse return null;
    const bounds_right = addExtent(bounds.x, bounds.width) orelse return null;
    const bounds_bottom = addExtent(bounds.y, bounds.height) orelse return null;
    const left = @max(destination.x, bounds.x);
    const top = @max(destination.y, bounds.y);
    const right = @min(destination_right, bounds_right);
    const bottom = @min(destination_bottom, bounds_bottom);
    if (left >= right or top >= bottom) {
        return null;
    }

    const clipped_left: u64 = @intCast(left - destination.x);
    const clipped_top: u64 = @intCast(top - destination.y);
    const clipped_right: u64 = @intCast(destination_right - right);
    const clipped_bottom: u64 = @intCast(destination_bottom - bottom);
    const source_left = scaleCeil(clipped_left, source.width, destination.width);
    const source_top = scaleCeil(clipped_top, source.height, destination.height);
    const source_right = scaleCeil(clipped_right, source.width, destination.width);
    const source_bottom = scaleCeil(clipped_bottom, source.height, destination.height);
    if (source_left + source_right >= source.width or
        source_top + source_bottom >= source.height)
    {
        return null;
    }

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
    const product = @as(u128, value) * numerator;
    return @intCast((product + denominator - 1) / denominator);
}

const Clip = struct {
    destination: Rect,
    source: Rect,
};
