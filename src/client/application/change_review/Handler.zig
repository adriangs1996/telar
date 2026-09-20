const core = @import("telar-core");
const std = @import("std");
const Model = @import("../../model/Model.zig");
const Session = @import("../../change_review/Session.zig");
const Operation = @import("../../connection/ChangeReviewOperation.zig");
const Pane = @import("../../panes/Pane.zig");
const Handler = @This();

model: *Model,
session: *Session,

/// Opens any attached pane, including an agent launched in an ordinary terminal.
/// Example: `try handler.open(pane_id);`
pub fn open(self: Handler, pane_id: core.PaneId) !void {
    const pane = self.find(pane_id) orelse return error.ChangeReviewPaneUnavailable;
    self.session.open(.{ .pane_id = pane.id, .pane_generation = pane.pane_generation, .attachment_generation = pane.attachment_generation, .location = pane.location, .view_generation = 0, .edition_id = 0 });
    self.invalidate();
}

/// Resolves the review owner without retaining an address across lifecycle changes.
/// Example: `if (!handler.isAttached()) closeReview();`
pub fn isAttached(self: Handler) bool {
    const owner = self.session.owner orelse return false;
    return self.resolve(owner) != null;
}

/// Example: `handler.close();`
pub fn close(self: Handler) void {
    self.session.close();
    self.invalidate();
}

/// Captures the attached owner for a bounded, correlated request.
/// Example: `const operation = try handler.operation(edition_id);`
pub fn operation(self: Handler, edition_id: u64) !Operation {
    if (self.session.session_changed) {
        return error.RetiredChangeReviewSession;
    }
    if (self.session.pending != null) {
        return error.ChangeReviewRequestPending;
    }
    var owner = self.session.owner orelse return error.ChangeReviewClosed;
    if (self.resolve(owner) == null) {
        return error.ChangeReviewPaneUnavailable;
    }
    owner.edition_id = edition_id;
    if (self.session.loaded) {
        try owner.setSession(self.session.snapshot.session);
    }
    return owner;
}

/// Example: `handler.begin(request_id);`
pub fn begin(self: Handler, request_id: core.RequestId) void {
    self.session.begin(request_id);
    self.invalidate();
}

/// Applies a reply only while both the attachment and view still exist.
/// Example: `_ = try handler.apply(operation, response);`
pub fn apply(self: Handler, owner: Operation, response: core.ChangeReviewSnapshotView) !bool {
    if (self.resolve(owner) == null) {
        _ = self.failed(owner, "The pane was detached; reopen its review");
        return false;
    }
    const applied = try self.session.apply(owner, response);
    if (applied) {
        self.invalidate();
    }
    return applied;
}

/// Accepts invalidation only for this connection's current pane attachment.
/// Example: `_ = handler.changed(notification);`
pub fn changed(self: Handler, notification: core.ChangeReviewChanged) bool {
    const owner = self.session.owner orelse return false;
    if (self.resolve(owner) == null or !self.session.changed(notification)) {
        return false;
    }
    self.invalidate();
    return true;
}

/// Retains review content and exposes failure without clearing adapter drafts.
/// Example: `_ = handler.failed(operation, message);`
pub fn failed(self: Handler, owner: Operation, message: []const u8) bool {
    if (!self.session.failed(owner, message)) {
        return false;
    }
    self.invalidate();
    return true;
}

/// Example: `handler.report("The review is still loading");`
pub fn report(self: Handler, message: []const u8) void {
    self.session.report(message);
    self.invalidate();
}

fn find(self: Handler, pane_id: core.PaneId) ?*const Pane {
    const pane = self.model.workspace.findPane(pane_id) orelse return null;
    return if (pane.attached and pane.pane_generation != 0) pane else null;
}

fn resolve(self: Handler, owner: Operation) ?*const Pane {
    const pane = self.find(owner.pane_id) orelse return null;
    return if (pane.pane_generation == owner.pane_generation and pane.attachment_generation == owner.attachment_generation) pane else null;
}

fn invalidate(self: Handler) void {
    self.model.chrome_revision +%= 1;
}

test "change review handler accepts terminal panes and rejects replaced attachments" {
    const model = try std.testing.allocator.create(Model);
    defer std.testing.allocator.destroy(model);
    model.* = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const session = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(session);
    session.* = .{};
    const pane_id: core.PaneId = @enumFromInt(1);
    const location: core.TabLocation = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) };
    try model.workspace.bootstrap(.{ .pane_id = pane_id, .location = location, .size = .{ .cols = 20, .rows = 5 } });
    const pane = model.workspace.findPane(pane_id).?;
    _ = pane.identify(.terminal, 3);
    const use_case: Handler = .{ .model = model, .session = session };
    try use_case.open(pane_id);
    try std.testing.expect(use_case.isAttached());
    const pending_owner = try use_case.operation(0);
    use_case.begin(@enumFromInt(21));
    try std.testing.expectError(error.ChangeReviewRequestPending, use_case.operation(0));
    const response: core.ChangeReviewSnapshotView = .{ .request_id = @enumFromInt(21), .pane_id = pane_id, .pane_generation = 3, .edition_id = 1, .patch = "immutable" };
    pane.attachment_generation += 1;
    try std.testing.expect(!use_case.isAttached());
    try std.testing.expect(!try use_case.apply(pending_owner, response));
    try std.testing.expect(!session.loaded);
    try std.testing.expect(session.errorSlice().len > 0);
}
