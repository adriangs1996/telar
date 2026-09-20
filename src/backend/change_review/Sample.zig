const core = @import("telar-core");
const std = @import("std");
identity: [32]u8,
path: [core.change_review.max_path_bytes]u8 = undefined,
path_len: u16,
content: [core.change_review.max_sample_bytes]u8 = undefined,
content_len: u16,
exists: bool,
created_ms: i64,

pub fn init(sample: core.ReportChangeReviewSample, identity: [32]u8, created_ms: i64) @This() {
    var value: @This() = .{ .identity = identity, .path_len = @intCast(sample.path.len), .content_len = @intCast(sample.content.len), .exists = sample.exists, .created_ms = created_ms };
    @memcpy(value.path[0..sample.path.len], sample.path);
    @memcpy(value.content[0..sample.content.len], sample.content);
    return value;
}
