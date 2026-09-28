//! One clipboard image decoded for the window's preview shelf: a thumbnail
//! for its card and a larger copy for the preview modal. `sequence` is the
//! clipboard capture it belongs to, so adoption pairs it with that capture
//! only.
const std = @import("std");
const PremultipliedImage = @import("PremultipliedImage.zig");
const PreviewImage = @This();

sequence: u64,
thumbnail: PremultipliedImage,
full: PremultipliedImage,

/// Example: `preview.deinit(gpa);`
pub fn deinit(self: *PreviewImage, gpa: std.mem.Allocator) void {
    self.thumbnail.deinit(gpa);
    self.full.deinit(gpa);
    self.* = undefined;
}
