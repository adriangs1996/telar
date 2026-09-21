//! Review state, exact attachment admission and correlated runtime requests.
const std = @import("std");
const Model = @import("../../model/Model.zig");
const core = @import("telar-core");
const Client = @import("../../AttachedClient.zig");
const Pane = @import("../../panes/Pane.zig");
const Operation = @import("../../connection/ChangeReviewOperation.zig");
const lifecycle = @import("../../connection/request_lifecycle.zig");
const runtime_io = @import("../../entrypoints/runtime_io.zig");

/// Opens the latest review for any attached pane, preserving an already open edition.
/// Example: `try change_review.open(client, pane_id);`
pub fn open(client: *Client, pane_id: core.PaneId) !void {
    try openSession(client, pane_id);
    try query(client, if (client.change_review.loaded) client.change_review.snapshot.edition_id else 0);
}

/// Zero requests latest; explicit navigation never replaces a review on new edits.
/// Example: `try change_review.query(client, snapshot.next_edition_id);`
pub fn query(client: *Client, edition_id: u64) !void {
    const owner = operation(client, edition_id) catch |err| {
        report(client, @errorName(err));
        return err;
    };
    const request_id = try lifecycle.nextId(client);
    try lifecycle.register(client, .{ .request_id = request_id, .continuation = .{ .change_review_query = owner } });
    begin(client, request_id);
    runtime_io.enqueueChangeReviewQuery(client, .{ .request_id = request_id, .pane_id = owner.pane_id, .pane_generation = owner.pane_generation, .edition_id = edition_id, .session = owner.sessionSlice() }) catch |err| {
        _ = lifecycle.consume(client, request_id);
        _ = failed(client, owner, @errorName(err));
        return err;
    };
}

/// Sends one mutation while retaining both the canonical snapshot and local draft.
/// Pass the displayed edition and revision to bind a delayed gesture to its owner.
/// Example: `try change_review.command(client, request);`
pub fn command(client: *Client, request: core.ChangeReviewCommand) !void {
    if (!client.change_review.loaded) {
        report(client, "No change review is loaded");
        return error.ChangeReviewNotLoaded;
    }
    const edition_id = if (request.edition_id == 0) client.change_review.snapshot.edition_id else request.edition_id;
    const owner = operation(client, edition_id) catch |err| {
        report(client, @errorName(err));
        return err;
    };
    var outgoing = request;
    outgoing.request_id = try lifecycle.nextId(client);
    outgoing.pane_id = owner.pane_id;
    outgoing.pane_generation = owner.pane_generation;
    outgoing.edition_id = edition_id;
    outgoing.session = owner.sessionSlice();
    if (outgoing.expected_revision == 0) {
        outgoing.expected_revision = client.change_review.snapshot.revision;
    }
    try lifecycle.register(client, .{ .request_id = outgoing.request_id, .continuation = .{ .change_review_command = owner } });
    begin(client, outgoing.request_id);
    runtime_io.enqueueChangeReviewCommand(client, outgoing) catch |err| {
        _ = lifecycle.consume(client, outgoing.request_id);
        _ = failed(client, owner, @errorName(err));
        return err;
    };
}

/// Copies borrowed wire content before the next receive can overwrite it.
/// Example: `_ = try change_review.apply(client, response);`
pub fn apply(client: *Client, response: core.ChangeReviewSnapshotView) !bool {
    const continuation = lifecycle.consume(client, response.request_id) orelse return false;
    const owner: Operation = switch (continuation) {
        .change_review_query, .change_review_command => |owner| owner,
        .ignored => {
            retired(client, response.request_id);
            return false;
        },
        else => return error.UnexpectedControlReply,
    };
    const accepted = applyResponse(client, owner, response) catch |err| {
        _ = failed(client, owner, @errorName(err));
        return false;
    };
    return accepted;
}

/// Drains notices after the view consumes mutation success or failure, so a later
/// refresh can never be mistaken for the acknowledgement of an earlier save.
/// Example: `change_review.refreshInvalidated(client);`
pub fn refreshInvalidated(client: *Client) void {
    if (client.change_review.needsRefresh() and client.change_review.errorSlice().len == 0) {
        query(client, if (client.change_review.loaded) client.change_review.snapshot.edition_id else 0) catch {};
    }
}

/// Retires a correlated reply after pane or tab removal without leaving a busy view.
/// Example: `change_review.retired(client, request_id);`
pub fn retired(client: *Client, request_id: core.RequestId) void {
    if (client.change_review.pending != request_id) {
        return;
    }
    const owner = client.change_review.owner orelse return;
    _ = failed(client, owner, "The pane was detached; reopen its review");
}

/// Opens any attached pane, including an agent launched in an ordinary terminal.
/// Example: `try openSession(client, pane_id);`
fn openSession(client: *Client, pane_id: core.PaneId) !void {
    const pane = find(client, pane_id) orelse return error.ChangeReviewPaneUnavailable;
    client.change_review.open(.{ .pane_id = pane.id, .pane_generation = pane.pane_generation, .attachment_generation = pane.attachment_generation, .location = pane.location, .view_generation = 0, .edition_id = 0 });
    invalidate(client);
}

/// Resolves the review owner without retaining an address across lifecycle changes.
/// Example: `if (!isAttached(client)) closeReview();`
pub fn isAttached(client: *Client) bool {
    const owner = client.change_review.owner orelse return false;
    return resolve(client, owner) != null;
}

/// Example: `close(client);`
pub fn close(client: *Client) void {
    client.change_review.close();
    invalidate(client);
}

/// Captures the attached owner for a bounded, correlated request.
/// Example: `const owner = try operation(client, edition_id);`
pub fn operation(client: *Client, edition_id: u64) !Operation {
    if (client.change_review.session_changed) {
        return error.RetiredChangeReviewSession;
    }
    if (client.change_review.pending != null) {
        return error.ChangeReviewRequestPending;
    }
    var owner = client.change_review.owner orelse return error.ChangeReviewClosed;
    if (resolve(client, owner) == null) {
        return error.ChangeReviewPaneUnavailable;
    }
    owner.edition_id = edition_id;
    if (client.change_review.loaded) {
        try owner.setSession(client.change_review.snapshot.session);
    }
    return owner;
}

/// Example: `begin(client, request_id);`
pub fn begin(client: *Client, request_id: core.RequestId) void {
    client.change_review.begin(request_id);
    invalidate(client);
}

/// Applies a reply only while both the attachment and view still exist.
/// Example: `_ = try applyResponse(client, owner, response);`
fn applyResponse(client: *Client, owner: Operation, response: core.ChangeReviewSnapshotView) !bool {
    if (resolve(client, owner) == null) {
        _ = failed(client, owner, "The pane was detached; reopen its review");
        return false;
    }
    const applied = try client.change_review.apply(owner, response);
    if (applied) {
        invalidate(client);
    }
    return applied;
}

/// Retains pane availability even when its review is closed, and refreshes an open view.
/// Example: `_ = changed(client, notification);`
pub fn changed(client: *Client, notification: core.ChangeReviewChanged) bool {
    const pane = find(client, notification.pane_id) orelse return false;
    const availability_changed = pane.applyChangeReview(notification);
    const review_changed = if (client.change_review.owner) |owner| resolve(client, owner) != null and client.change_review.changed(notification) else false;
    if (!availability_changed and !review_changed) {
        return false;
    }
    invalidate(client);
    return true;
}

/// Retains review content and exposes failure without clearing adapter drafts.
/// Example: `_ = failed(client, owner, message);`
pub fn failed(client: *Client, owner: Operation, message: []const u8) bool {
    if (!client.change_review.failed(owner, message)) {
        return false;
    }
    invalidate(client);
    return true;
}

/// Example: `report(client, "The review is still loading");`
pub fn report(client: *Client, message: []const u8) void {
    client.change_review.report(message);
    invalidate(client);
}

fn find(client: *Client, pane_id: core.PaneId) ?*Pane {
    const pane = client.model.workspace.findPane(pane_id) orelse return null;
    return if (pane.attached and pane.pane_generation != 0) pane else null;
}

fn resolve(client: *Client, owner: Operation) ?*const Pane {
    const pane = find(client, owner.pane_id) orelse return null;
    return if (pane.pane_generation == owner.pane_generation and pane.attachment_generation == owner.attachment_generation) pane else null;
}

fn invalidate(client: *Client) void {
    client.model.chrome_revision +%= 1;
}

test "change review operation accepts terminal panes and rejects replaced attachments" {
    const client = try std.testing.allocator.create(Client);
    const model = &client.model;
    defer std.testing.allocator.destroy(client);
    model.* = Model.init(std.testing.allocator, true);
    defer model.deinit();
    client.change_review = .{};
    const session = &client.change_review;
    const pane_id: core.PaneId = @enumFromInt(1);
    const location: core.TabLocation = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) };
    try model.workspace.bootstrap(.{ .pane_id = pane_id, .location = location, .size = .{ .cols = 20, .rows = 5 } });
    const pane = model.workspace.findPane(pane_id).?;
    _ = pane.identify(.terminal, 3);
    try openSession(client, pane_id);
    try std.testing.expect(isAttached(client));
    const pending_owner = try operation(client, 0);
    begin(client, @enumFromInt(21));
    try std.testing.expectError(error.ChangeReviewRequestPending, operation(client, 0));
    const response: core.ChangeReviewSnapshotView = .{ .request_id = @enumFromInt(21), .pane_id = pane_id, .pane_generation = 3, .edition_id = 1, .patch = "immutable" };
    pane.attachment_generation += 1;
    try std.testing.expect(!isAttached(client));
    try std.testing.expect(!try applyResponse(client, pending_owner, response));
    try std.testing.expect(!session.loaded);
    try std.testing.expect(session.errorSlice().len > 0);
}

test "change review operation updates closed review availability without opening or querying a view" {
    const client = try std.testing.allocator.create(Client);
    const model = &client.model;
    defer std.testing.allocator.destroy(client);
    model.* = Model.init(std.testing.allocator, true);
    defer model.deinit();
    client.change_review = .{};
    const session = &client.change_review;
    const pane_id: core.PaneId = @enumFromInt(1);
    const location: core.TabLocation = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) };
    try model.workspace.bootstrap(.{ .pane_id = pane_id, .location = location, .size = .{ .cols = 20, .rows = 5 } });
    const pane = model.workspace.findPane(pane_id).?;
    _ = pane.identify(.terminal, 3);
    var notification: core.ChangeReviewChanged = .{ .pane_id = pane_id, .pane_generation = 3, .session = "hook-session", .latest_edition_id = 1 };
    const revision = model.chrome_revision;
    try std.testing.expect(changed(client, notification));
    try std.testing.expect(model.chrome_revision != revision);
    try std.testing.expect(pane.hasChangeReview());
    try std.testing.expect(session.owner == null);
    try std.testing.expect(!session.needsRefresh());
    try std.testing.expect(!changed(client, notification));

    try openSession(client, pane_id);
    notification.latest_edition_id = 2;
    try std.testing.expect(changed(client, notification));
    try std.testing.expect(session.needsRefresh());
    close(client);
    try std.testing.expect(pane.hasChangeReview());
    notification.session = "next-hook-session";
    notification.latest_edition_id = 0;
    try std.testing.expect(changed(client, notification));
    try std.testing.expect(!pane.hasChangeReview());
    try std.testing.expect(!session.needsRefresh());
    notification.pane_generation += 1;
    notification.latest_edition_id = 1;
    try std.testing.expect(!changed(client, notification));
    try std.testing.expect(!pane.hasChangeReview());
}
