//! Owned immutable response prepared entirely off the input and rendering paths.
const syntaxhl = @import("syntaxhl");
const std = @import("std");
const client = @import("telar-client");
const LiveResponse = @import("LiveResponse.zig");
const DiffHighlighter = @import("../../syntax/DiffHighlighter.zig");
const Self = @This();

pub const max_bytes = 256 * 1024;
allocator: std.mem.Allocator,
parsed: std.json.Parsed(LiveResponse),
revisions: [2]client.ChangeReviewRevision = @splat(.{}),
roles: [2][syntaxhl.limits.source_bytes]syntaxhl.Role = undefined,

/// Retains all JSON strings and computes syntax before publishing the snapshot.
/// Example: `const snapshot = try LiveSnapshot.parse(io, allocator, bytes);`
pub fn parse(io: std.Io, allocator: std.mem.Allocator, bytes: []const u8) !*Self {
    if (bytes.len > max_bytes) {
        return error.ReviewResponseTooLarge;
    }

    const parsed = try std.json.parseFromSlice(LiveResponse, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    const value = parsed.value;
    if (value.schema != 1 or value.session_id.len == 0 or value.session_id.len > 64 or value.revisions.len == 0 or value.revisions.len > 2 or value.comments.len > client.change_review_limits.comments) {
        return error.InvalidReviewResponse;
    }

    if ((value.status == .complete and value.revisions.len != 2) or ((value.status == .reviewable or value.status == .working) and value.revisions.len != 1) or (value.revisions.len == 2 and std.mem.eql(u8, value.revisions[0].id, value.revisions[1].id))) {
        return error.InvalidReviewResponse;
    }

    if (value.@"error") |message| {
        if (message.len > 256) {
            return error.InvalidReviewResponse;
        }
    }

    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{ .allocator = allocator, .parsed = parsed };
    for (value.revisions, 0..) |revision, index| {
        if (revision.id.len == 0 or revision.id.len > 64 or revision.patch.len > syntaxhl.limits.source_bytes or !std.unicode.utf8ValidateSlice(revision.patch)) {
            return error.InvalidReviewRevision;
        }

        try self.revisions[index].load(revision.patch);
        try self.revisions[index].ensureReviewable();
        var worker: DiffHighlighter = .{ .allocator = allocator, .io = io, .text = revision.patch, .roles = self.roles[index][0..revision.patch.len] };
        try worker.run();
    }

    for (value.comments) |comment| {
        if (comment.file.len == 0 or comment.file.len > std.fs.max_path_bytes or comment.body.len == 0 or comment.body.len > client.change_review_limits.comment_bytes or !std.unicode.utf8ValidateSlice(comment.body) or comment.first_line == 0 or comment.last_line < comment.first_line) {
            return error.InvalidReviewComment;
        }
    }

    return self;
}

pub fn deinit(self: *Self) void {
    self.parsed.deinit();
    self.allocator.destroy(self);
}
