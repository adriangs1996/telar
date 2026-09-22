//! Connects one disposable review surface to the runtime's acknowledged editions.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Widget = @import("Widget.zig");
const PreparedEdition = @import("PreparedEdition.zig");
const Inbox = @import("../gui_event.zig").Inbox;
const dispatch = @import("dispatch.zig");
const Self = @This();
const Pending = @import("Pending.zig");

allocator: std.mem.Allocator,
widget: Widget = .{ .mode = .runtime, .layer = 1 },
active: bool = false,
version: u64 = 0,
revision: u64 = 0,
edition: u64 = 0,
previous: u64 = 0,
next: u64 = 0,
slots: [2]PreparedEdition = @splat(.{}),
visible_slot: usize = 0,
job: ?usize = null,
notified: bool = false,
pending: ?Pending = null,
blocked: bool = false,
refreshing: bool = false,
status_bytes: [1024]u8 = undefined,
paste: client.ChangeReviewComment = .{},
paste_generation: ?u64 = null,
paste_revision: u64 = 0,
paste_failed: bool = false,

/// Keeps one pane's unacknowledged edits alive until its runtime reply arrives.
/// Example: `try panel.open(app, pane_id);`
pub fn open(self: *Self, app: *client.AttachedClient, pane_id: core.PaneId) !void {
    const state = &app.change_review;
    if (state.owner) |owner| {
        if (owner.pane_id == pane_id and app.isChangeReviewAttached() and !state.session_changed) {
            self.active = true;
            self.widget.changedOwner();
            if (state.pending == null) {
                try app.queryChangeReview(self.edition);
            }
            return;
        }
        if ((self.dirty() or state.pending != null) and app.isChangeReviewAttached() and !state.session_changed) {
            self.active = true;
            self.status("Finish saving this review before opening another pane.");
            return;
        }
    }

    try app.openChangeReview(pane_id);
    self.active = true;
    self.edition = 0;
    self.revision = 0;
    self.pending = null;
    self.blocked = false;
    self.widget.resetNavigation();
    self.widget.model = .{};
    self.widget.changed_comments = 0;
    self.widget.deleted_comments = 0;
    self.widget.reviewed_changed = false;
    self.widget.edition_id = 0;
    self.widget.source_label = "";
    self.widget.previous_edition = false;
    self.widget.next_edition = false;
    self.widget.delivery = .idle;
    self.widget.read_only = true;
    self.widget.loading = true;
    self.widget.changedOwner();
    self.status("Loading recorded changes...");
}

/// Called before preparing a frame, after the preceding GPU borrow has ended.
/// Example: `try panel.synchronize(app);`
pub fn synchronize(self: *Self, app: *client.AttachedClient) !void {
    const state = &app.change_review;
    if (state.owner == null) {
        self.active = false;
        return;
    }
    if (!app.isChangeReviewAttached() or state.session_changed) {
        self.widget.read_only = true;
        self.widget.loading = false;
        self.widget.model.editing = null;
        self.status("The pane or agent session changed. This view retains its draft; copy it before closing.");
        if (self.widget.command == .close) {
            self.widget.command = null;
            self.active = false;
            self.widget.changedOwner();
            app.closeChangeReview();
        }
        return;
    }
    if (self.notified) {
        const prepared = &self.slots[self.job.?];
        if (state.loaded and prepared.generation == state.generation and prepared.edition == state.snapshot.edition_id) {
            if (prepared.failure) |err| {
                self.widget.loading = false;
                self.widget.read_only = true;
                self.status(switch (err) {
                    error.SyntaxLimit, error.SyntaxUnavailable => "Syntax highlighting could not finish. Refresh to retry this edition.",
                    error.ReviewFileLimit, error.ReviewLineLimit => "This edition exceeds the file or line limit of the review view.",
                    else => "This edition could not be prepared for review. Refresh to retry.",
                });
            } else {
                self.visible_slot = self.job.?;
                self.adopt(&state.snapshot);
            }
        }
        self.job = null;
        self.notified = false;
    }

    if (self.version != state.version) {
        self.version = state.version;
        if (state.pending == null and state.errorSlice().len != 0) {
            if (self.pending) |pending| {
                self.restore(pending);
                self.pending = null;
                self.blocked = true;
            }
            self.refreshing = false;
            self.widget.loading = false;
            self.status(state.errorSlice());
        } else if (state.loaded and state.pending == null) {
            const snapshot = &state.snapshot;
            const retry = self.refreshing;
            if (retry) {
                self.refreshing = false;
                self.blocked = false;
            }
            if (snapshot.edition_id == self.edition) {
                const conflicting = !retry and self.pending == null and self.dirty() and snapshot.revision != self.revision;
                if (self.pending) |pending| {
                    self.acknowledge(pending, snapshot);
                    self.pending = null;
                }
                self.merge(snapshot);
                if (conflicting) {
                    self.blocked = true;
                    self.status("This review changed in another client. Your draft is retained; refresh to retry saving it.");
                }
            } else if (snapshot.edition_id == 0) {
                self.widget.loading = false;
                self.status(snapshot.status);
            } else {
                self.widget.loading = true;
                self.widget.read_only = true;
            }
        }
    }

    if (state.pending != null or self.job != null) {
        return;
    }
    if (self.widget.command) |command| {
        if (command == .refresh) {
            self.widget.command = null;
            self.refreshing = true;
            try app.queryChangeReview(if (state.loaded) state.snapshot.edition_id else self.edition);
            return;
        }
    }
    if (self.blocked) {
        return;
    }
    if (state.loaded and state.snapshot.edition_id == self.edition and self.edition != 0) {
        if (try self.flush(app)) {
            return;
        }
    }
    if (self.widget.command) |command| {
        self.widget.command = null;
        switch (command) {
            .close => {
                self.active = false;
                self.widget.changedOwner();
            },
            .previous_edition, .next_edition => {
                const edition = if (command == .previous_edition) self.previous else self.next;
                if (edition != 0) {
                    try app.queryChangeReview(edition);
                    self.widget.loading = true;
                    self.widget.read_only = true;
                    self.widget.model.editing = null;
                    self.widget.changedOwner();
                }
            },
            .refresh => unreachable,
        }
    }
    if (self.active) {
        app.refreshChangeReview();
    }
}

/// Copies one bounded patch and starts its index/highlight work off the UI path.
/// Example: `panel.start(.{ .app = app, .inbox = inbox });`
pub fn start(self: *Self, context: struct { app: *client.AttachedClient, inbox: *Inbox }) void {
    const state = &context.app.change_review;
    if (self.job != null or !state.loaded or state.snapshot.edition_id == 0 or state.snapshot.edition_id == self.edition or !self.widget.loading) {
        return;
    }
    const index = 1 - self.visible_slot;
    const slot = &self.slots[index];
    slot.generation = state.generation;
    slot.edition = state.snapshot.edition_id;
    slot.len = state.snapshot.patch.len;
    @memcpy(slot.source[0..slot.len], state.snapshot.patch);
    self.job = index;
    context.inbox.start(.change_review_ready, .{ execute, .{ self, context.inbox.io } }) catch {
        self.job = null;
        self.widget.loading = false;
        self.status("Review preparation is busy. Refresh to retry.");
    };
}

pub fn notify(self: *Self) void {
    self.notified = true;
}

/// Pins a native paste to the editor and accumulates it atomically within its quota.
/// Example: `panel.beginPaste();`
pub fn beginPaste(self: *Self) void {
    self.paste = .{};
    self.paste_generation = self.widget.generation;
    self.paste_revision = self.widget.text_revision;
    self.paste_failed = self.widget.activeField() == null;
}

pub fn appendPaste(self: *Self, bytes: []const u8) void {
    if (self.paste_failed or bytes.len > self.paste.body.bytes.len - self.paste.body.len) {
        self.paste_failed = true;
        return;
    }
    _ = self.paste.body.replace(.{ @intCast(self.paste.body.len), @intCast(self.paste.body.len) }, bytes);
}

pub fn endPaste(self: *Self) !void {
    defer self.paste_generation = null;
    if (self.paste_failed or !self.active or self.paste_generation != self.widget.generation or self.paste_revision != self.widget.text_revision) {
        self.status("Paste cancelled: the editor changed or the comment limit was exceeded.");
        return;
    }
    _ = try dispatch.apply(&self.widget, .{ .paste = self.paste.body.text() });
}

fn execute(self: *Self, io: std.Io) void {
    self.slots[self.job.?].build(.{ .allocator = self.allocator, .io = io });
}

fn adopt(self: *Self, snapshot: *const core.ChangeReviewSnapshotView) void {
    self.widget.resetNavigation();
    self.widget.model = .{};
    self.widget.model.revisions[0] = self.slots[self.visible_slot].revision;
    @memcpy(self.widget.roles[0][0..snapshot.patch.len], self.slots[self.visible_slot].roles[0..snapshot.patch.len]);
    self.widget.model.selectFile(0);
    self.widget.scroll = 0;
    self.widget.sidebar_start = 0;
    self.widget.changed_comments = 0;
    self.widget.deleted_comments = 0;
    self.widget.reviewed_changed = false;
    self.widget.loading = false;
    self.widget.edition_id = snapshot.edition_id;
    self.edition = snapshot.edition_id;
    self.widget.changedOwner();
    self.merge(snapshot);
}

fn merge(self: *Self, snapshot: *const core.ChangeReviewSnapshotView) void {
    self.revision = snapshot.revision;
    self.widget.source_label = if (snapshot.source == .observed_snapshot) "Before/after snapshot" else "Agent-reported patch";
    self.previous = snapshot.previous_edition_id;
    self.next = snapshot.next_edition_id;
    self.widget.previous_edition = self.previous != 0;
    self.widget.next_edition = self.next != 0;
    self.widget.read_only = snapshot.delivery != .idle;
    if (snapshot.delivery != .idle) {
        self.widget.delivery = if (snapshot.delivery == .pending) .pending else .sent;
        self.widget.model.editing = null;
    }
    if (!self.widget.reviewed_changed) {
        for (self.widget.model.current().files[0..self.widget.model.current().file_count]) |*file| {
            file.reviewed = snapshot.reviewed;
        }
    }
    for (&self.widget.model.comments, 0..) |*local, index| {
        if (local.id == 0 or self.localChange(index)) {
            continue;
        }
        var found = false;
        for (snapshot.comments()) |comment| {
            if (comment.id == local.id) {
                found = true;
                break;
            }
        }
        if (!found) {
            local.alive = false;
            local.id = 0;
        }
    }
    for (snapshot.comments()) |comment| {
        const index = self.findComment(comment.id) orelse self.emptyComment() orelse continue;
        if (self.localChange(index)) {
            continue;
        }
        const anchor = self.resolveAnchor(comment) orelse continue;
        const local = &self.widget.model.comments[index];
        local.id = comment.id;
        local.anchor = anchor;
        local.alive = true;
        local.draft = comment.draft;
        if (!std.mem.eql(u8, local.body.text(), comment.body)) {
            _ = local.body.replace(.{ 0, @intCast(local.body.len) }, comment.body);
        }
    }
    if (self.dirty()) {
        self.status("Saving review to the runtime...");
    } else if (snapshot.status.len != 0) {
        self.status(snapshot.status);
    } else if (snapshot.latest_edition_id != snapshot.edition_id) {
        self.status("A newer edition is available. This review remains on its original edition.");
    } else {
        self.status(if (snapshot.source == .observed_snapshot) "Recorded before/after snapshot · Review saved in the runtime" else "Agent-reported patch · Review saved in the runtime");
    }
}

fn flush(self: *Self, app: *client.AttachedClient) !bool {
    for (&self.widget.model.comments, 0..) |*comment, index| {
        const bit = mask(index);
        if (self.widget.deleted_comments & bit != 0) {
            if (comment.id == 0) {
                self.widget.deleted_comments &= ~bit;
                comment.pending = false;
                continue;
            }
            var request = self.makeRequest(.delete_comment);
            request.comment_id = comment.id;
            if (!self.send(app, .{ .request = request, .pending = .{ .action = .delete_comment, .index = index } })) {
                return false;
            }
            self.widget.deleted_comments &= ~bit;
            return true;
        }
        if (self.widget.changed_comments & bit != 0 and comment.alive) {
            const revision = self.widget.model.current();
            const first_row = revision.rows[comment.anchor.first].value;
            const end = revision.rows[comment.anchor.last].value;
            var request = self.makeRequest(.save_comment);
            request.comment_id = comment.id;
            request.path = revision.files[comment.anchor.file].path;
            request.first_line = @intCast((if (comment.anchor.before) first_row.old else first_row.new) orelse return error.InvalidReviewAnchor);
            request.last_line = @intCast((if (comment.anchor.before) end.old else end.new) orelse return error.InvalidReviewAnchor);
            request.side = if (comment.anchor.before) .before else .after;
            request.body = comment.body.text();
            request.draft = comment.draft;
            if (!self.send(app, .{ .request = request, .pending = .{ .action = .save_comment, .index = index } })) {
                return false;
            }
            self.widget.changed_comments &= ~bit;
            comment.pending = true;
            return true;
        }
    }
    if (self.widget.reviewed_changed) {
        var request = self.makeRequest(.mark_reviewed);
        request.reviewed = self.widget.model.current().files[0].reviewed;
        if (!self.send(app, .{ .request = request, .pending = .{ .action = .mark_reviewed } })) {
            return false;
        }
        self.widget.reviewed_changed = false;
        return true;
    }
    if (self.widget.delivery == .queued) {
        for (self.widget.model.comments) |comment| {
            if (comment.alive and comment.draft) {
                self.widget.delivery = .idle;
                self.status("Save or delete every draft before sending the review.");
                return false;
            }
        }
        if (!self.send(app, .{ .request = self.makeRequest(.submit), .pending = .{ .action = .submit } })) {
            return false;
        }
        self.widget.read_only = true;
        self.widget.delivery = .sending;
        return true;
    }
    return false;
}

fn makeRequest(self: *const Self, action: core.change_review.Action) core.ChangeReviewCommand {
    return .{ .request_id = @enumFromInt(0), .pane_id = @enumFromInt(0), .pane_generation = 0, .edition_id = self.edition, .expected_revision = self.revision, .action = action };
}

fn send(self: *Self, app: *client.AttachedClient, value: struct { request: core.ChangeReviewCommand, pending: Pending }) bool {
    app.commandChangeReview(value.request) catch |err| {
        self.blocked = true;
        self.status(@errorName(err));
        return false;
    };
    self.pending = value.pending;
    self.status("Saving review to the runtime...");
    return true;
}

fn acknowledge(self: *Self, pending: Pending, snapshot: *const core.ChangeReviewSnapshotView) void {
    const index = pending.index orelse return;
    const local = &self.widget.model.comments[index];
    if (pending.action == .delete_comment) {
        local.* = .{};
        return;
    }
    if (local.id == 0) {
        for (snapshot.comments()) |comment| {
            if (self.findComment(comment.id) == null) {
                const anchor = self.resolveAnchor(comment) orelse continue;
                if (std.meta.eql(anchor, local.anchor)) {
                    local.id = comment.id;
                    break;
                }
            }
        }
    }
    local.pending = self.widget.deleted_comments & mask(index) != 0;
}

fn restore(self: *Self, pending: Pending) void {
    if (pending.index) |index| {
        if (pending.action == .delete_comment) {
            self.widget.deleted_comments |= mask(index);
        } else {
            self.widget.changed_comments |= mask(index);
        }
        self.widget.model.comments[index].pending = false;
    } else if (pending.action == .mark_reviewed) {
        self.widget.reviewed_changed = true;
    } else if (pending.action == .submit) {
        self.widget.delivery = .pending;
        self.widget.read_only = true;
    }
}

fn resolveAnchor(self: *Self, comment: core.ChangeReviewComment) ?client.ChangeReviewAnchor {
    const revision = self.widget.model.current();
    const file = revision.findFile(comment.path) orelse return null;
    var first: ?usize = null;
    var last: ?usize = null;
    const before = comment.side == .before;
    for (revision.rows[revision.files[file].first..revision.files[file].last], revision.files[file].first..) |row, index| {
        const number = (if (before) row.value.old else row.value.new) orelse continue;
        if (number == comment.first_line) {
            first = index;
        }
        if (number == comment.last_line) {
            last = index;
        }
    }
    return .{ .revision = 0, .file = file, .first = first orelse return null, .last = last orelse return null, .before = before };
}

fn findComment(self: *const Self, id: u64) ?usize {
    for (self.widget.model.comments, 0..) |comment, index| {
        if (comment.id == id) {
            return index;
        }
    }
    return null;
}

fn emptyComment(self: *const Self) ?usize {
    for (self.widget.model.comments, 0..) |comment, index| {
        if (!comment.alive and !comment.pending and !self.localChange(index)) {
            return index;
        }
    }
    return null;
}

fn localChange(self: *const Self, index: usize) bool {
    return (self.widget.changed_comments | self.widget.deleted_comments) & mask(index) != 0 or self.widget.model.comments[index].pending;
}

fn dirty(self: *const Self) bool {
    return self.widget.changed_comments != 0 or self.widget.deleted_comments != 0 or self.widget.reviewed_changed or self.pending != null;
}

fn status(self: *Self, message: []const u8) void {
    var len = @min(message.len, self.status_bytes.len);
    while (len > 0 and !std.unicode.utf8ValidateSlice(message[0..len])) {
        len -= 1;
    }
    @memcpy(self.status_bytes[0..len], message[0..len]);
    self.widget.model.status = self.status_bytes[0..len];
}

fn mask(index: usize) u32 {
    return @as(u32, 1) << @as(u5, @intCast(index));
}
