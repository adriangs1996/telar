const std = @import("std");
const core = @import("telar-core");
const Edition = @This();

id: u64 = 0,
revision: u64 = 1,
source: core.change_review.Source = .provider_patch,
patch: [core.change_review.max_patch_bytes]u8 = undefined,
patch_len: u32 = 0,
identity: [32]u8 = @splat(0),
comment_storage: [core.change_review.max_comments]Comment = @splat(.{}),
comment_count: u8 = 0,
next_comment: u64 = 1,
reviewed: bool = false,
delivery: core.change_review.Delivery = .idle,
feedback_id: u64 = 0,
feedback: [core.change_review.max_feedback_bytes]u8 = undefined,
feedback_len: u16 = 0,
/// Bytes of the reported diff this edition left out because it passed
/// `max_patch_bytes`; zero when the edition holds the whole diff.
omitted_patch_bytes: u32 = 0,
/// Comments the last submission left out of the feedback because they did
/// not fit `max_feedback_bytes`. Not retained: it reports that submission.
omitted_feedback_comments: u8 = 0,

const Comment = @import("Comment.zig");
const DiffLine = core.ChangeReviewDiffLine;

/// Bytes a recounted hunk header may take beyond the original's trailing
/// text: its markers, separators and four 32-bit numbers.
const recounted_header_bytes = 52;
/// Bytes kept free at the end of the feedback for the line that counts the
/// comments left out.
const omitted_note_bytes = 128;

/// Owns an immutable, complete patch independently of provider transcript retention.
/// Example: `try edition.setPatch(patch);`.
pub fn setPatch(self: *Edition, patch: []const u8) !void {
    if (patch.len > self.patch.len) {
        return error.InvalidPatch;
    }

    try validatePatch(patch);
    @memcpy(self.patch[0..patch.len], patch);
    self.patch_len = @intCast(patch.len);
    self.omitted_patch_bytes = 0;
}

/// Keeps the part of `patch` that fits the edition: its whole files and
/// hunks, then the first lines of the hunk that crosses the bound under a
/// header recounted for them. Returns how many bytes it left out; a patch
/// whose first hunk has no change that fits is `ReviewPatchTooLarge`.
///
/// ```zig
/// const omitted = try edition.setFittingPatch(patch);
/// ```
pub fn setFittingPatch(self: *Edition, patch: []const u8) !usize {
    if (patch.len <= self.patch.len) {
        try self.setPatch(patch);
        return 0;
    }

    const kept = fit(&self.patch, patch);
    if (kept == 0) {
        return error.ReviewPatchTooLarge;
    }

    validatePatch(self.patch[0..kept]) catch return error.ReviewPatchTooLarge;
    self.patch_len = @intCast(kept);
    self.omitted_patch_bytes = @intCast(patch.len - kept);
    return patch.len - kept;
}

/// Writes into `buffer` the longest prefix of `patch` that ends before a
/// file's header or before a hunk that is not its file's first, or up to
/// the hunk crossing the end with only the lines of it that fit, and
/// returns its length. A file is never kept without a hunk.
fn fit(buffer: []u8, patch: []const u8) usize {
    var lines: core.ChangeReviewDiffLines = .{
        .text = patch,
    };
    var boundary: usize = 0;
    var hunk_start: ?usize = null;
    var file_hunks: usize = 0;
    var previous: ?DiffLine.Kind = null;
    while (true) {
        const start = lines.index;
        const line = lines.next() orelse break;
        if (line.kind == .file) {
            if (previous != null and previous.? != .file and start <= buffer.len) {
                boundary = start;
            }

            hunk_start = null;
            file_hunks = 0;
        } else if (line.kind == .hunk) {
            if (file_hunks != 0 and start <= buffer.len) {
                boundary = start;
            }

            hunk_start = start;
            file_hunks += 1;
        }

        if (lines.index > buffer.len) {
            break;
        }

        previous = line.kind;
    }

    if (hunk_start) |start| {
        if (start >= boundary) {
            const recounted = recount(buffer, patch, start);
            if (recounted != 0) {
                return recounted;
            }
        }
    }

    @memcpy(buffer[0..boundary], patch[0..boundary]);
    return boundary;
}

/// Writes `patch` up to the hunk at `start`, that hunk's header recounted
/// and the lines of it that fit; zero when they hold no change.
fn recount(buffer: []u8, patch: []const u8, start: usize) usize {
    var lines: core.ChangeReviewDiffLines = .{
        .text = patch,
        .index = start,
    };
    const header = lines.next() orelse return 0;
    const closing = std.mem.indexOfPos(u8, header.text, 2, "@@") orelse return 0;
    const trailing = header.text[closing + 2 ..];
    const body_start = lines.index;
    const header_bound = recounted_header_bytes + trailing.len;
    if (start + header_bound > buffer.len) {
        return 0;
    }

    var body_end = body_start;
    var old_lines: u32 = 0;
    var new_lines: u32 = 0;
    var changed = false;
    while (lines.next()) |line| {
        if (line.kind == .file or line.kind == .hunk) {
            break;
        }

        if (start + header_bound + (lines.index - body_start) > buffer.len) {
            break;
        }

        switch (line.kind) {
            .context => {
                old_lines += 1;
                new_lines += 1;
            },
            .removed => {
                old_lines += 1;
                changed = true;
            },
            .added => {
                new_lines += 1;
                changed = true;
            },
            else => {},
        }

        body_end = lines.index;
    }

    if (!changed) {
        return 0;
    }

    @memcpy(buffer[0..start], patch[0..start]);
    const written = std.fmt.bufPrint(buffer[start..], "@@ -{d},{d} +{d},{d} @@{s}\n", .{ header.old.?, old_lines, header.new.?, new_lines, trailing }) catch return 0;
    const body = patch[body_start..body_end];
    const offset = start + written.len;
    @memcpy(buffer[offset..][0..body.len], body);
    return offset + body.len;
}

fn validatePatch(patch: []const u8) !void {
    if (patch.len == 0 or !std.unicode.utf8ValidateSlice(patch) or std.mem.indexOfScalar(u8, patch, 0) != null) {
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
            if (index == null and self.comment_count == core.change_review.max_comments) {
                return error.ReviewCommentCapacity;
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
        .submit => try self.writeFeedback(),
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

/// Formats the saved comments for the agent. A comment whose excerpt does
/// not fit keeps its text without the excerpt, one that does not fit at all
/// is left out, and the last line says how many were.
fn writeFeedback(self: *Edition) !void {
    var writer: std.Io.Writer = .fixed(self.feedback[0 .. self.feedback.len - omitted_note_bytes]);
    try writer.print("Please address this Telar review of edition {d}. The excerpts identify the reviewed version; inspect the current file before correcting it.\n", .{self.id});

    var count: usize = 0;
    var omitted: u8 = 0;
    for (self.comment_storage[0..self.comment_count]) |*comment| {
        if (comment.draft) {
            continue;
        }

        count += 1;
        const mark = writer.end;
        self.writeComment(&writer, comment, true) catch {
            writer.end = mark;
            self.writeComment(&writer, comment, false) catch {
                writer.end = mark;
                omitted += 1;
            };
        };
    }

    if (count == 0) {
        return error.NoSavedComments;
    }

    var length = writer.end;
    if (omitted != 0) {
        var note: std.Io.Writer = .fixed(self.feedback[length..]);
        note.print("\n{d} more comments did not fit the feedback limit of {d} bytes; they remain in Telar's review.\n", .{ omitted, core.change_review.max_feedback_bytes }) catch {};
        length += note.end;
    }

    self.feedback_len = @intCast(length);
    self.omitted_feedback_comments = omitted;
    self.feedback_id = self.id;
    self.delivery = .pending;
}

fn writeComment(self: *const Edition, writer: *std.Io.Writer, comment: *const Comment, with_excerpt: bool) !void {
    try writer.print("\nFile: {s}\nSide: {s}; lines {d}-{d}\nComment: {s}\n", .{ comment.pathSlice(), @tagName(comment.side), comment.first_line, comment.last_line, comment.bodySlice() });
    if (!with_excerpt) {
        try writer.writeAll("Reviewed excerpt: too long for the feedback; open the review in Telar.\n");
        return;
    }

    try writer.writeAll("Reviewed excerpt:\n");
    try self.excerpt(writer, comment.view());
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

test "a diff at the patch limit is kept whole and one byte past it with a single line is refused" {
    const gpa = std.testing.allocator;
    const edition = try gpa.create(Edition);
    defer gpa.destroy(edition);
    edition.* = .{
        .id = 1,
    };

    const prefix = "Added a.zig\n@@ -0,0 +1 @@\n+";
    const patch = try gpa.alloc(u8, core.change_review.max_patch_bytes + 1);
    defer gpa.free(patch);
    @memcpy(patch[0..prefix.len], prefix);
    @memset(patch[prefix.len..], 'x');

    const exact = patch[0..core.change_review.max_patch_bytes];
    exact[exact.len - 1] = '\n';
    try std.testing.expectEqual(@as(usize, 0), try edition.setFittingPatch(exact));
    try std.testing.expectEqual(@as(u32, core.change_review.max_patch_bytes), edition.patch_len);
    try std.testing.expectEqual(@as(u32, 0), edition.omitted_patch_bytes);

    exact[exact.len - 1] = 'x';
    patch[patch.len - 1] = '\n';
    try std.testing.expectError(error.ReviewPatchTooLarge, edition.setFittingPatch(patch));
}

test "a diff past the patch limit keeps its whole hunks and recounts the hunk it cuts" {
    const gpa = std.testing.allocator;
    const edition = try gpa.create(Edition);
    defer gpa.destroy(edition);
    edition.* = .{
        .id = 1,
    };

    var hunks: std.Io.Writer.Allocating = .init(gpa);
    defer hunks.deinit();
    try hunks.writer.writeAll("Updated a.zig\n");
    var line: u32 = 1;
    while (hunks.written().len <= core.change_review.max_patch_bytes) : (line += 10) {
        try hunks.writer.print("@@ -{d},2 +{d},2 @@ fn f{d}\n-old {d}\n+new {d}\n context\n", .{ line, line, line, line, line });
    }

    const patch = hunks.written();
    const omitted = try edition.setFittingPatch(patch);
    try std.testing.expect(omitted > 0);
    try std.testing.expectEqual(patch.len, edition.patch_len + omitted);
    try std.testing.expectEqual(@as(u32, @intCast(omitted)), edition.omitted_patch_bytes);
    try std.testing.expect(edition.patch_len <= core.change_review.max_patch_bytes);
    try validatePatch(edition.text());

    var one: std.Io.Writer.Allocating = .init(gpa);
    defer one.deinit();
    const rows = core.change_review.max_patch_bytes / "+line\n".len;
    try one.writer.print("Added big.zig\n@@ -0,0 +1,{d} @@\n", .{rows});
    for (0..rows) |_| {
        try one.writer.writeAll("+line\n");
    }

    const single = one.written();
    try std.testing.expect(single.len > core.change_review.max_patch_bytes);
    try std.testing.expect(try edition.setFittingPatch(single) > 0);
    try validatePatch(edition.text());
    try std.testing.expect(std.mem.startsWith(u8, edition.text(), "Added big.zig\n@@ -0,0 +1,"));
    try std.testing.expect(std.mem.endsWith(u8, edition.text(), "+line\n"));
}

test "a cut past a file's git header keeps the files before it, never the header alone" {
    const first = "diff --git a/one.zig b/one.zig\nindex 1111111..2222222 100644\n--- a/one.zig\n+++ b/one.zig\n@@ -1 +1 @@\n-a\n+b\n";
    const second_header = "diff --git a/two.zig b/two.zig\nindex 3333333..4444444 100644\n--- a/two.zig\n+++ b/two.zig\n";
    const second_hunk = "@@ -1,2 +1,2 @@\n-c\n+d\n";
    const patch = first ++ second_header ++ second_hunk;

    // Room for the second header and the start of its hunk header, but not
    // for a recounted hunk with a change.
    var buffer: [first.len + second_header.len + 4]u8 = undefined;
    const kept = fit(&buffer, patch);
    try std.testing.expectEqualStrings(first, buffer[0..kept]);
}

test "feedback keeps the comments that fit and counts the rest" {
    const gpa = std.testing.allocator;
    const edition = try gpa.create(Edition);
    defer gpa.destroy(edition);
    edition.* = .{
        .id = 1,
    };
    try edition.setPatch("Updated file.zig\n@@ -1,2 +1,2 @@\n-old\n+new\n context\n");

    const body: [core.change_review.max_comment_bytes]u8 = @splat('c');
    var command: core.ChangeReviewCommand = .{
        .request_id = @enumFromInt(1),
        .pane_id = @enumFromInt(2),
        .pane_generation = 3,
        .edition_id = 1,
        .expected_revision = 1,
        .action = .save_comment,
        .path = "file.zig",
        .first_line = 1,
        .last_line = 2,
        .body = &body,
    };
    for (0..core.change_review.max_comments) |_| {
        command.expected_revision = edition.revision;
        try edition.apply(command);
    }

    command.expected_revision = edition.revision;
    command.action = .submit;
    try edition.apply(command);

    const feedback = edition.feedback[0..edition.feedback_len];
    const kept = std.mem.count(u8, feedback, "\nComment: ");
    try std.testing.expect(kept > 0);
    try std.testing.expectEqual(@as(usize, core.change_review.max_comments), kept + edition.omitted_feedback_comments);
    try std.testing.expect(edition.omitted_feedback_comments > 0);
    try std.testing.expect(std.mem.indexOf(u8, feedback, "more comments did not fit the feedback limit") != null);
    try std.testing.expectEqual(core.change_review.Delivery.pending, edition.delivery);
}
