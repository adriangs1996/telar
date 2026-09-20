//! Disposable, bounded replica for the one review open in a client connection.
const std = @import("std");
const core = @import("telar-core");
const Operation = @import("../connection/ChangeReviewOperation.zig");
const Session = @This();
const status_capacity = 1024;
const storage_capacity = core.change_review.max_identity_bytes + core.change_review.max_patch_bytes + core.change_review.max_feedback_bytes + status_capacity + core.change_review.max_comments * (core.change_review.max_path_bytes + core.change_review.max_comment_bytes);

owner: ?Operation = null,
generation: u64 = 0,
version: u64 = 0,
loaded: bool = false,
invalidated_edition: u64 = 0,
session_changed: bool = false,
pending: ?core.RequestId = null,
snapshot: core.ChangeReviewSnapshotView = undefined,
bytes: [storage_capacity]u8 = undefined,
error_bytes: [status_capacity]u8 = undefined,
error_len: usize = 0,

/// Reopening an attached review preserves its edition until explicit navigation.
/// Example: `session.open(owner);`
pub fn open(self: *Session, owner: Operation) void {
    const same = if (self.owner) |old| !self.session_changed and old.pane_id == owner.pane_id and old.pane_generation == owner.pane_generation and old.attachment_generation == owner.attachment_generation else false;
    self.generation +%= 1;
    self.owner = owner;
    self.owner.?.view_generation = self.generation;
    self.pending = null;
    self.error_len = 0;
    self.loaded = same and self.loaded;
    if (!same) {
        self.invalidated_edition = 0;
        self.session_changed = false;
    }
    self.version +%= 1;
}

/// Retires replies without granting a closed view authority to consume them.
/// Example: `session.close();`
pub fn close(self: *Session) void {
    self.generation +%= 1;
    self.owner = null;
    self.pending = null;
    self.loaded = false;
    self.invalidated_edition = 0;
    self.session_changed = false;
    self.version +%= 1;
}

/// Records one admitted request; callers retain drafts until the reply arrives.
/// Example: `session.begin(request_id);`
pub fn begin(self: *Session, request_id: core.RequestId) void {
    self.pending = request_id;
    self.error_len = 0;
    self.version +%= 1;
}

/// Validates all borrowed data before replacing the last usable snapshot.
/// Example: `_ = try session.apply(operation, snapshot);`
pub fn apply(self: *Session, operation: Operation, value: core.ChangeReviewSnapshotView) !bool {
    if (!self.matches(operation) or self.pending != value.request_id) {
        return false;
    }
    if (self.session_changed or (operation.session_len != 0 and !std.mem.eql(u8, operation.sessionSlice(), value.session))) {
        return error.RetiredChangeReviewSession;
    }
    if (value.session.len > core.change_review.max_identity_bytes) {
        return error.ChangeReviewSnapshotTooLarge;
    }
    if (value.pane_id != operation.pane_id or value.pane_generation != operation.pane_generation or (operation.edition_id != 0 and value.edition_id != operation.edition_id)) {
        return error.InvalidChangeReviewOwner;
    }
    if (value.comment_count > core.change_review.max_comments or value.patch.len > core.change_review.max_patch_bytes or value.feedback.len > core.change_review.max_feedback_bytes or value.status.len > status_capacity) {
        return error.ChangeReviewSnapshotTooLarge;
    }
    if (self.loaded and value.edition_id == self.snapshot.edition_id and value.revision < self.snapshot.revision) {
        return error.StaleChangeReviewSnapshot;
    }
    if (self.loaded and value.edition_id == self.snapshot.edition_id and (!std.mem.eql(u8, value.patch, self.snapshot.patch) or value.source != self.snapshot.source)) {
        return error.ChangeReviewEditionChanged;
    }
    for (value.comments()) |comment| {
        if (comment.path.len > core.change_review.max_path_bytes or comment.body.len > core.change_review.max_comment_bytes) {
            return error.ChangeReviewSnapshotTooLarge;
        }
    }

    self.snapshot = value;
    var offset: usize = 0;
    self.snapshot.session = self.own(value.session, &offset);
    self.snapshot.patch = self.own(value.patch, &offset);
    self.snapshot.feedback = self.own(value.feedback, &offset);
    self.snapshot.status = self.own(value.status, &offset);
    for (self.snapshot.comment_storage[0..value.comment_count]) |*comment| {
        comment.path = self.own(comment.path, &offset);
        comment.body = self.own(comment.body, &offset);
    }
    self.loaded = true;
    if (value.latest_edition_id >= self.invalidated_edition) {
        self.invalidated_edition = 0;
    }
    self.pending = null;
    self.error_len = 0;
    self.version +%= 1;
    return true;
}

/// Coalesces new editions without replacing the content currently being reviewed.
/// Example: `_ = session.changed(notification);`
pub fn changed(self: *Session, notification: core.ChangeReviewChanged) bool {
    const owner = self.owner orelse return false;
    if (owner.pane_id != notification.pane_id or owner.pane_generation != notification.pane_generation) {
        return false;
    }
    if (self.loaded and self.snapshot.session.len != 0 and !std.mem.eql(u8, self.snapshot.session, notification.session)) {
        if (self.session_changed) {
            return false;
        }
        self.session_changed = true;
        self.report("The agent conversation changed. Close this review to open its current conversation.");
        return true;
    }
    const known = if (self.loaded) self.snapshot.latest_edition_id else 0;
    if (notification.latest_edition_id <= @max(known, self.invalidated_edition)) {
        return false;
    }
    self.invalidated_edition = notification.latest_edition_id;
    self.version +%= 1;
    return true;
}

/// Example: `if (session.needsRefresh()) queryCurrentEdition();`
pub fn needsRefresh(self: *const Session) bool {
    return self.owner != null and self.pending == null and self.invalidated_edition != 0 and !self.session_changed;
}

/// Rejections never discard the retained patch, comments or adapter draft.
/// Example: `_ = session.failed(operation, "Review changed; reload and retry");`
pub fn failed(self: *Session, operation: Operation, message: []const u8) bool {
    if (!self.matches(operation)) {
        return false;
    }
    self.pending = null;
    self.report(message);
    return true;
}

/// Copies a transport failure before borrowed error storage can be reused.
/// Example: `session.report(@errorName(err));`
pub fn report(self: *Session, message: []const u8) void {
    self.error_len = @min(message.len, self.error_bytes.len);
    while (self.error_len > 0 and !std.unicode.utf8ValidateSlice(message[0..self.error_len])) {
        self.error_len -= 1;
    }
    @memcpy(self.error_bytes[0..self.error_len], message[0..self.error_len]);
    self.version +%= 1;
}

/// Example: `drawStatus(session.errorSlice());`
pub fn errorSlice(self: *const Session) []const u8 {
    return self.error_bytes[0..self.error_len];
}

/// Example: `if (!session.matches(operation)) return;`
pub fn matches(self: *const Session, operation: Operation) bool {
    const owner = self.owner orelse return false;
    return self.generation == operation.view_generation and owner.pane_id == operation.pane_id and owner.pane_generation == operation.pane_generation and owner.attachment_generation == operation.attachment_generation;
}

fn own(self: *Session, value: []const u8, offset: *usize) []const u8 {
    const result = self.bytes[offset.*..][0..value.len];
    @memcpy(result, value);
    offset.* += value.len;
    return result;
}

fn testOwner() Operation {
    return .{ .pane_id = @enumFromInt(4), .pane_generation = 8, .attachment_generation = 3, .view_generation = 0, .edition_id = 0, .location = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(2) } };
}

test "change review replica owns borrowed snapshots and rejects late view replies" {
    const session = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(session);
    session.* = .{};
    session.open(testOwner());
    const owner = session.owner.?;
    session.begin(@enumFromInt(21));
    var patch = "old patch".*;
    var body = "keep draft".*;
    var path = "code.zig".*;
    var response: core.ChangeReviewSnapshotView = .{ .request_id = @enumFromInt(21), .pane_id = owner.pane_id, .pane_generation = owner.pane_generation, .edition_id = 1, .revision = 2, .patch = &patch, .comment_count = 1 };
    response.comment_storage[0] = .{ .id = 1, .path = &path, .first_line = 2, .last_line = 4, .body = &body, .draft = true };
    try std.testing.expect(try session.apply(owner, response));
    @memset(&patch, 'x');
    @memset(&body, 'x');
    @memset(&path, 'x');
    try std.testing.expectEqualStrings("old patch", session.snapshot.patch);
    try std.testing.expectEqualStrings("keep draft", session.snapshot.comments()[0].body);
    try std.testing.expectEqualStrings("code.zig", session.snapshot.comments()[0].path);
    session.open(testOwner());
    session.begin(@enumFromInt(22));
    try std.testing.expect(!try session.apply(owner, response));
    try std.testing.expectEqual(@as(?core.RequestId, @enumFromInt(22)), session.pending);
    try std.testing.expectEqualStrings("old patch", session.snapshot.patch);
}

test "change review failure and malformed response preserve the previous edition" {
    const session = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(session);
    session.* = .{};
    session.open(testOwner());
    const owner = session.owner.?;
    session.begin(@enumFromInt(21));
    var response: core.ChangeReviewSnapshotView = .{ .request_id = @enumFromInt(21), .pane_id = owner.pane_id, .pane_generation = owner.pane_generation, .edition_id = 1, .revision = 2, .patch = "patch" };
    try std.testing.expect(try session.apply(owner, response));
    session.begin(@enumFromInt(22));
    response.request_id = @enumFromInt(22);
    response.revision = 1;
    try std.testing.expectError(error.StaleChangeReviewSnapshot, session.apply(owner, response));
    try std.testing.expect(session.failed(owner, "conflict"));
    try std.testing.expectEqualStrings("patch", session.snapshot.patch);
    try std.testing.expectEqualStrings("conflict", session.errorSlice());
    try std.testing.expectEqual(@as(u64, 2), session.snapshot.revision);
    session.begin(@enumFromInt(23));
    response.request_id = @enumFromInt(23);
    response.revision = 3;
    response.patch = "replacement";
    try std.testing.expectError(error.ChangeReviewEditionChanged, session.apply(owner, response));
    try std.testing.expectEqualStrings("patch", session.snapshot.patch);
    session.close();
    try std.testing.expect(!session.failed(owner, "late error"));
}

test "change review invalidations coalesce while busy and provider conversations cannot reuse editions" {
    const session = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(session);
    session.* = .{};
    session.open(testOwner());
    var owner = session.owner.?;
    session.begin(@enumFromInt(21));
    const first: core.ChangeReviewSnapshotView = .{ .request_id = @enumFromInt(21), .pane_id = owner.pane_id, .pane_generation = owner.pane_generation, .session = "thread-A", .edition_id = 1, .latest_edition_id = 1, .revision = 2, .patch = "patch" };
    try std.testing.expect(try session.apply(owner, first));
    try owner.setSession(session.snapshot.session);
    session.begin(@enumFromInt(22));
    const notification: core.ChangeReviewChanged = .{ .pane_id = owner.pane_id, .pane_generation = owner.pane_generation, .session = "thread-A", .latest_edition_id = 2 };
    try std.testing.expect(session.changed(notification));
    try std.testing.expect(!session.changed(notification));
    try std.testing.expect(!session.needsRefresh());
    var second = first;
    second.request_id = @enumFromInt(22);
    try std.testing.expect(try session.apply(owner, second));
    try std.testing.expect(session.needsRefresh());
    try std.testing.expectEqualStrings("patch", session.snapshot.patch);
    session.begin(@enumFromInt(23));
    second.request_id = @enumFromInt(23);
    second.session = "thread-B";
    try std.testing.expectError(error.RetiredChangeReviewSession, session.apply(owner, second));
    var retired = notification;
    retired.session = "thread-B";
    retired.latest_edition_id = 0;
    try std.testing.expect(session.changed(retired));
    try std.testing.expect(session.session_changed);
    try std.testing.expectEqualStrings("thread-A", session.snapshot.session);
    try std.testing.expect(!session.needsRefresh());
    session.open(testOwner());
    try std.testing.expect(!session.loaded);
    try std.testing.expect(!session.session_changed);
    try std.testing.expectEqual(@as(usize, 0), session.errorSlice().len);
    session.close();
    session.open(testOwner());
    try std.testing.expect(!session.session_changed);
}
