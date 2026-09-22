//! Copies saved comment bodies before an asynchronous delivery can outlive edits.
const client = @import("telar-client");
const std = @import("std");
const ReviewFeedback = @import("ReviewFeedback.zig");
const Self = @This();

revision_id: []const u8 = "",
comments: [client.change_review_limits.comments]client.ChangeReviewComment = @splat(.{}),
feedback: [client.change_review_limits.comments]ReviewFeedback = undefined,
count: usize = 0,

/// Paths borrow a retained snapshot; bodies belong to this submission.
/// Example: `try submission.capture(model, revision_id);`
pub fn capture(self: *Self, model: *const client.ChangeReviewModel, revision_id: []const u8) !void {
    self.count = 0;
    self.revision_id = revision_id;
    for (model.comments) |comment| {
        if (!comment.alive or comment.draft) {
            continue;
        }

        const anchor = comment.anchor;
        if (anchor.revision != 0) {
            return error.ReviewAlreadyCorrected;
        }

        const revision = &model.revisions[anchor.revision];
        const first = revision.rows[anchor.first].value;
        const last = revision.rows[anchor.last].value;
        self.comments[self.count] = comment;
        self.feedback[self.count] = .{ .file = revision.files[anchor.file].path, .side = if (anchor.before) .before else .after, .first_line = (if (anchor.before) first.old else first.new) orelse return error.InvalidReviewAnchor, .last_line = (if (anchor.before) last.old else last.new) orelse return error.InvalidReviewAnchor, .body = self.comments[self.count].body.text() };
        self.count += 1;
    }

    if (self.count == 0) {
        return error.NoSavedComments;
    }
}

pub fn write(self: *const Self, writer: *std.Io.Writer) !void {
    try std.json.Stringify.value(.{ .schema = 1, .action = "submit", .request_id = "review-1", .revision_id = self.revision_id, .comments = self.feedback[0..self.count] }, .{}, writer);
}

test "review prototype delivery copies bodies and exports file coordinates instead of diff row offsets" {
    const model = try std.testing.allocator.create(client.ChangeReviewModel);
    defer std.testing.allocator.destroy(model);
    model.* = .{};
    try model.revisions[0].load("Updated sample.py\n@@ -20,2 +30,2 @@\n-old\n+first\n+second\n-old2\n");
    model.selectFile(0);
    model.select(.{ .row = 1, .extend = false });
    model.select(.{ .row = 2, .extend = true });
    model.comment();
    _ = model.comments[0].body.replace(.{ 0, 0 }, "Review café\nSecond line");
    model.save();
    var submission: Self = .{};
    try submission.capture(model, "immutable-id");
    _ = model.comments[0].body.replace(.{ 0, @intCast(model.comments[0].body.len) }, "changed locally");
    try std.testing.expectEqual(@as(u32, 30), submission.feedback[0].first_line);
    try std.testing.expectEqual(@as(u32, 31), submission.feedback[0].last_line);
    try std.testing.expectEqualStrings("Review café\nSecond line", submission.feedback[0].body);
    try std.testing.expectEqualStrings("sample.py", submission.feedback[0].file);
}
