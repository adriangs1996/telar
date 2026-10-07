//! Decodes a bounded clipboard PNG into the two sizes the window shows: a
//! thumbnail that fits one shelf card and a copy for the preview modal.
//! Runs in the clipboard capture worker, never on the interactive path.
const std = @import("std");
const data = @import("model");
const imaging = @import("imaging");
const png = imaging.png;
const box_filter = imaging.box_filter;
const premultiply = imaging.premultiply;
const ImageView = imaging.ImageView;
const PremultipliedImage = @import("PremultipliedImage.zig");
const PreviewImage = @import("PreviewImage.zig");

/// The square a thumbnail fits in; the shelf's texture holds one per card.
pub const thumbnail_side: u32 = 256;
/// Bounds of the modal copy, one texture of the window's frame budget.
pub const full_max_side: u32 = 2048;
pub const full_max_pixels: u32 = 2 * 1024 * 1024;

/// Decodes `bytes` and resamples it into both preview sizes. The caller owns
/// the result.
/// Example: `var preview = try preview_decode.decode(gpa, capture.png, capture.request.sequence);`
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8, sequence: u64) !PreviewImage {
    var decoded = try png.decode(
        gpa,
        bytes,
        .{
            .max_side = std.math.maxInt(u32),
            .max_pixels = data.attachment_types.max_pixels,
        },
    );
    defer {
        std.crypto.secureZero(u8, decoded.pixels);
        decoded.deinit(gpa);
    }

    const source = decoded.view();
    var full = try resampled(gpa, source, fit(source.width, source.height, full_max_side, full_max_pixels));
    errdefer full.deinit(gpa);

    var thumbnail = try resampled(gpa, source, fit(source.width, source.height, thumbnail_side, thumbnail_side * thumbnail_side));
    errdefer thumbnail.deinit(gpa);

    return .{
        .sequence = sequence,
        .thumbnail = thumbnail,
        .full = full,
    };
}

/// The largest size with the aspect of `width` by `height` that fits both
/// bounds, never larger than the source and never empty.
/// Example: `const size = preview_decode.fit(3000, 2000, 2048, 2 * 1024 * 1024);`
pub fn fit(width: u32, height: u32, max_side: u32, max_pixels: u32) [2]u32 {
    std.debug.assert(width != 0 and height != 0);
    const source_width: f64 = @floatFromInt(width);
    const source_height: f64 = @floatFromInt(height);
    const side_scale = @as(f64, @floatFromInt(max_side)) / @max(source_width, source_height);
    const area_scale = @sqrt(@as(f64, @floatFromInt(max_pixels)) / (source_width * source_height));
    const scale = @min(1, @min(side_scale, area_scale));

    return .{
        @max(1, @min(width, @as(u32, @intFromFloat(@floor(source_width * scale))))),
        @max(1, @min(height, @as(u32, @intFromFloat(@floor(source_height * scale))))),
    };
}

fn resampled(gpa: std.mem.Allocator, source: ImageView, size: [2]u32) !PremultipliedImage {
    var image = try PremultipliedImage.init(gpa, size[0], size[1]);
    errdefer image.deinit(gpa);

    box_filter.resampleRect(source, image.pixels, size[0], size[1]);
    premultiply.inPlace(image.pixels);
    return image;
}
