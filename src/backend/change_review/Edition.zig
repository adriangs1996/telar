const std = @import("std");
const core = @import("telar-core");
const limits = core.change_review;
const Edition = @This();

id: u64 = 0,
revision: u64 = 1,
source: limits.Source = .provider_patch,
patch: [limits.max_patch_bytes]u8 = undefined,
patch_len: u32 = 0,
identity: [32]u8 = @splat(0),
comment_storage: [limits.max_comments]Comment = @splat(.{}),
comment_count: u8 = 0,
next_comment: u64 = 1,
reviewed: bool = false,
delivery: limits.Delivery = .idle,
feedback_id: u64 = 0,
feedback: [limits.max_feedback_bytes]u8 = undefined,
feedback_len: u16 = 0,

const Comment = @import("Comment.zig");

/// Owns an immutable, complete patch independently of provider transcript retention.
/// Example: `try edition.setPatch(patch);`.
pub fn setPatch(self: *Edition, patch: []const u8) !void {
    if (patch.len == 0 or patch.len > self.patch.len or !std.unicode.utf8ValidateSlice(patch) or std.mem.indexOfScalar(u8, patch, 0) != null) {
        return error.InvalidPatch;
    }
    var lines: core.ChangeReviewDiffLines = .{ .text = patch };
    var changed = false;
    while (true) {
        const remaining = lines.old_left != 0 or lines.new_left != 0;
        const line = lines.next() orelse {
            if (remaining) {
                return error.InvalidPatch;
            }
            break;
        };
        if ((line.kind == .file or line.kind == .hunk) and remaining) {
            return error.InvalidPatch;
        }
        if (line.kind == .added) {
            if (line.new == null) {
                return error.InvalidPatch;
            }
            changed = true;
        } else if (line.kind == .removed) {
            if (line.old == null) {
                return error.InvalidPatch;
            }
            changed = true;
        } else if (line.kind == .context and (line.old == null or line.new == null)) {
            return error.InvalidPatch;
        }
    }
    if (!changed) {
        return error.InvalidPatch;
    }
    @memcpy(self.patch[0..patch.len], patch);
    self.patch_len = @intCast(patch.len);
}

pub fn text(self: *const Edition) []const u8 {
    return self.patch[0..self.patch_len];
}

/// Mutations compare the canonical revision and preserve prior state on rejection.
/// Example: `try edition.apply(command);`.
pub fn apply(self: *Edition, command: core.ChangeReviewCommand) !void {
    if (command.action == .submit and self.delivery != .idle) {
        return;
    }
    if (command.expected_revision != self.revision) {
        return error.StaleReview;
    }
    if (self.delivery != .idle and command.action != .mark_reviewed) {
        return error.ReviewAlreadySubmitted;
    }
    switch (command.action) {
        .save_comment => {
            try self.validateAnchor(command);
            if (!command.draft and std.mem.trim(u8, command.body, " \t\r\n").len == 0) {
                return error.EmptyComment;
            }
            var index: ?usize = null;
            for (self.comment_storage[0..self.comment_count], 0..) |comment, at| {
                if (comment.id == command.comment_id) {
                    index = at;
                }
            }
            if (command.comment_id != 0 and index == null) {
                return error.CommentNotFound;
            }
            if (index == null and self.comment_count == limits.max_comments) {
                return error.ReviewCapacity;
            }
            const at = index orelse self.comment_count;
            const identifier = if (index != null) command.comment_id else self.next_comment;
            const replacement = try Comment.init(identifier, command);
            self.comment_storage[at] = replacement;
            if (index == null) {
                self.comment_count += 1;
                self.next_comment += 1;
            }
        },
        .delete_comment => {
            var index: ?usize = null;
            for (self.comment_storage[0..self.comment_count], 0..) |comment, at| {
                if (comment.id == command.comment_id) {
                    index = at;
                }
            }
            const at = index orelse return error.CommentNotFound;
            std.mem.copyForwards(Comment, self.comment_storage[at .. self.comment_count - 1], self.comment_storage[at + 1 .. self.comment_count]);
            self.comment_count -= 1;
        },
        .submit => {
            var writer: std.Io.Writer = .fixed(&self.feedback);
            try writer.print("Please address this Telar review of edition {d}. The excerpts identify the reviewed version; inspect the current file before correcting it.\n", .{self.id});
            var count: usize = 0;
            for (self.comment_storage[0..self.comment_count]) |*comment| {
                if (comment.draft) {
                    continue;
                }
                count += 1;
                try writer.print("\nFile: {s}\nSide: {s}; lines {d}-{d}\nComment: {s}\nReviewed excerpt:\n", .{ comment.pathSlice(), @tagName(comment.side), comment.first_line, comment.last_line, comment.bodySlice() });
                try self.excerpt(&writer, comment.view());
            }
            if (count == 0) {
                return error.NoSavedComments;
            }
            self.feedback_len = @intCast(writer.buffered().len);
            self.feedback_id = self.id;
            self.delivery = .pending;
        },
        .mark_reviewed => self.reviewed = command.reviewed,
        .feedback, .ack_feedback => return error.InvalidReviewAction,
    }
    self.revision += 1;
}

pub fn validateAnchor(self: *const Edition, command: core.ChangeReviewCommand) !void {
    if (command.first_line == 0 or command.last_line < command.first_line) {
        return error.InvalidReviewAnchor;
    }
    var lines: core.ChangeReviewDiffLines = .{ .text = self.text() };
    var selected_file = false;
    var first = false;
    var expected = command.first_line;
    while (lines.next()) |line| {
        if (line.kind == .file) {
            selected_file = std.mem.eql(u8, command.path, line.text);
            first = false;
        } else if (line.kind == .hunk) {
            first = false;
            expected = command.first_line;
        } else if (selected_file) {
            const number = (if (command.side == .before) line.old else line.new) orelse continue;
            if (number == command.first_line) {
                first = true;
            }
            if (first) {
                if (number != expected) {
                    return error.InvalidReviewAnchor;
                }
                if (number == command.last_line) {
                    return;
                }
                expected += 1;
            }
        }
    }
    return error.InvalidReviewAnchor;
}

fn excerpt(self: *const Edition, writer: *std.Io.Writer, comment: core.ChangeReviewComment) !void {
    var lines: core.ChangeReviewDiffLines = .{ .text = self.text() };
    var selected = false;
    while (lines.next()) |line| {
        if (line.kind == .file) {
            selected = std.mem.eql(u8, line.text, comment.path);
        } else if (selected) {
            const number = (if (comment.side == .before) line.old else line.new) orelse continue;
            if (number >= comment.first_line and number <= comment.last_line) {
                try writer.print("{d}: {s}\n", .{ number, line.text });
            }
        }
    }
}

pub fn view(self: *const Edition, target: core.QueryChangeReview) core.ChangeReviewSnapshotView {
    var value: core.ChangeReviewSnapshotView = .{
        .request_id = target.request_id,
        .pane_id = target.pane_id,
        .pane_generation = target.pane_generation,
        .revision = self.revision,
        .edition_id = self.id,
        .source = self.source,
        .patch = self.text(),
        .comment_count = self.comment_count,
        .reviewed = self.reviewed,
        .delivery = self.delivery,
        .feedback_id = if (self.delivery == .pending) self.feedback_id else 0,
        .feedback = if (self.delivery == .pending) self.feedback[0..self.feedback_len] else "",
    };
    for (self.comment_storage[0..self.comment_count], 0..) |*comment, index| {
        value.comment_storage[index] = comment.view();
    }
    return value;
}

test "review comments validate same-hunk ranges and preserve canonical state on stale writes" {
    const gpa = std.testing.allocator;
    const edition = try gpa.create(Edition);
    defer gpa.destroy(edition);
    edition.* = .{ .id = 1 };
    try edition.setPatch("Updated file.zig\n@@ -1,2 +1,2 @@\n-old\n+new\n context\n@@ -10 +10 @@\n-before\n+after\n");
    var command: core.ChangeReviewCommand = .{ .request_id = @enumFromInt(1), .pane_id = @enumFromInt(2), .pane_generation = 3, .edition_id = 1, .expected_revision = 1, .action = .save_comment, .path = "file.zig", .first_line = 1, .last_line = 2, .body = "", .draft = true };
    try edition.apply(command);
    try std.testing.expectEqual(@as(u8, 1), edition.comment_count);
    try std.testing.expectError(error.StaleReview, edition.apply(command));
    command.expected_revision = edition.revision;
    command.comment_id = 1;
    command.last_line = 10;
    try std.testing.expectError(error.InvalidReviewAnchor, edition.apply(command));
    command.last_line = 2;
    command.draft = false;
    try std.testing.expectError(error.EmptyComment, edition.apply(command));
    command.body = "Keep these two lines together.";
    try edition.apply(command);
    command.expected_revision = edition.revision;
    command.action = .submit;
    try edition.apply(command);
    try std.testing.expectEqual(core.change_review.Delivery.pending, edition.delivery);
    try std.testing.expect(std.mem.indexOf(u8, edition.feedback[0..edition.feedback_len], "1: new\n2: context") != null);
    const revision = edition.revision;
    try edition.apply(command);
    try std.testing.expectEqual(revision, edition.revision);
    command.action = .save_comment;
    command.expected_revision = edition.revision;
    try std.testing.expectError(error.ReviewAlreadySubmitted, edition.apply(command));
}
