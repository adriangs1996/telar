//! One before-edit file sample waiting for its after sample. Its content is
//! one allocation of exactly its length, so a group of small pending
//! samples costs what they hold, not the largest sample each.
const std = @import("std");
const core = @import("telar-core");
const Sample = @This();

identity: [32]u8,
path: [core.change_review.max_path_bytes]u8 = undefined,
path_len: u16,
content: []u8,
exists: bool,
created_ms: i64,

/// Copies one reported sample to the heap; `destroy` frees both parts.
///
/// ```zig
/// const sample = try Sample.create(gpa, reported, identity, now);
/// defer sample.destroy(gpa);
/// ```
pub fn create(gpa: std.mem.Allocator, sample: core.ReportChangeReviewSample, identity: [32]u8, created_ms: i64) !*Sample {
    const self = try gpa.create(Sample);
    errdefer gpa.destroy(self);

    self.* = .{
        .identity = identity,
        .path_len = @intCast(sample.path.len),
        .content = try gpa.dupe(u8, sample.content),
        .exists = sample.exists,
        .created_ms = created_ms,
    };
    @memcpy(self.path[0..sample.path.len], sample.path);
    return self;
}

/// Bytes a pending sample of `content_bytes` holds, its record included.
///
/// ```zig
/// const held = Sample.heldBytes(reported.content.len);
/// ```
pub fn heldBytes(content_bytes: usize) usize {
    return @sizeOf(Sample) + content_bytes;
}

pub fn destroy(self: *Sample, gpa: std.mem.Allocator) void {
    gpa.free(self.content);
    gpa.destroy(self);
}
