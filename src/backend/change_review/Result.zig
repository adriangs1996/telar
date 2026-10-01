const std = @import("std");
const core = @import("telar-core");
/// Bytes of the largest reply: a whole snapshot.
pub const capacity = core.change_review.max_snapshot_message_bytes;
gpa: std.mem.Allocator,
bytes: []u8,
len: usize = 0,
changed_edition: u64 = 0,
/// A limit the operation reached while keeping what fit, such as a diff cut
/// at `max_patch_bytes`; the runtime reports it when the job finishes.
limit: ?core.LimitReach = null,

pub fn init(gpa: std.mem.Allocator) !*@This() {
    const result = try gpa.create(@This());
    errdefer gpa.destroy(result);
    result.* = .{ .gpa = gpa, .bytes = try gpa.alloc(u8, capacity) };
    return result;
}

pub fn deinit(self: *@This()) void {
    const gpa = self.gpa;
    gpa.free(self.bytes);
    gpa.destroy(self);
}

pub fn snapshot(self: *const @This()) !core.ChangeReviewSnapshotView {
    return (try core.decodeServer(self.bytes[0..self.len])).change_review_snapshot;
}
