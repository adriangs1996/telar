//! Change review: opens a review of an agent's changes, queries its patch and
//! sends its comments.
const data = @import("model");
const core = @import("telar-core");
const attached_client_tests = @import("../attached_client_tests.zig");
const Client = @import("../AttachedClient.zig");

/// Opens the latest review for any attached pane, preserving an already open edition.
/// Example: `try change_review.openChangeReview(app, pane_id);`
pub fn openChangeReview(client: *Client, pane_id: core.PaneId) !void {
    try openChangeReviewSession(client, pane_id);
    try queryChangeReview(client, if (client.model.change_review.loaded) client.model.change_review.snapshot.edition_id else 0);
}

/// Zero requests latest; explicit navigation never replaces a review on new edits.
/// Example: `try change_review.queryChangeReview(app, edition_id);`
pub fn queryChangeReview(client: *Client, edition_id: u64) !void {
    const owner = changeReviewOperation(client, edition_id) catch |err| {
        reportChangeReview(client, @errorName(err));
        return err;
    };

    const request_id = try client.model.request_lifecycle.nextId();
    try client.model.request_lifecycle.tracker.add(
        request_id,
        .{
            .change_review_query = owner,
        },
    );
    beginChangeReview(client, request_id);
    sendRuntimeChangeReviewQuery(
        client,
        .{
            .request_id = request_id,
            .pane_id = owner.pane_id,
            .pane_generation = owner.pane_generation,
            .edition_id = edition_id,
            .session = owner.sessionSlice(),
        },
    ) catch |err| {
        _ = client.model.request_lifecycle.tracker.take(request_id);
        _ = failChangeReview(client, owner, @errorName(err));
        return err;
    };
}

/// Sends one mutation while retaining both the canonical snapshot and local draft.
/// Pass the displayed edition and revision to bind a delayed gesture to its owner.
/// Example: `try change_review.commandChangeReview(app, request);`
pub fn commandChangeReview(client: *Client, request: core.ChangeReviewCommand) !void {
    if (!client.model.change_review.loaded) {
        reportChangeReview(client, "No change review is loaded");
        return error.ChangeReviewNotLoaded;
    }

    const edition_id = if (request.edition_id == 0) client.model.change_review.snapshot.edition_id else request.edition_id;
    const owner = changeReviewOperation(client, edition_id) catch |err| {
        reportChangeReview(client, @errorName(err));
        return err;
    };

    var outgoing = request;
    outgoing.request_id = try client.model.request_lifecycle.nextId();
    outgoing.pane_id = owner.pane_id;
    outgoing.pane_generation = owner.pane_generation;
    outgoing.edition_id = edition_id;
    outgoing.session = owner.sessionSlice();
    if (outgoing.expected_revision == 0) {
        outgoing.expected_revision = client.model.change_review.snapshot.revision;
    }

    try client.model.request_lifecycle.tracker.add(
        outgoing.request_id,
        .{
            .change_review_command = owner,
        },
    );
    beginChangeReview(client, outgoing.request_id);
    sendRuntimeChangeReviewCommand(client, outgoing) catch |err| {
        _ = client.model.request_lifecycle.tracker.take(outgoing.request_id);
        _ = failChangeReview(client, owner, @errorName(err));
        return err;
    };
}

/// Drains notices after the view consumes mutation success or failure, so a later
/// refresh can never be mistaken for the acknowledgement of an earlier save.
/// Example: `change_review.refreshChangeReview(app);`
pub fn refreshChangeReview(client: *Client) void {
    if (client.model.change_review.needsRefresh() and client.model.change_review.errorSlice().len == 0) {
        queryChangeReview(client, if (client.model.change_review.loaded) client.model.change_review.snapshot.edition_id else 0) catch {};
    }
}

/// Resolves the review owner without retaining an address across lifecycle changes.
/// Example: `_ = change_review.isChangeReviewAttached(app);`
pub fn isChangeReviewAttached(client: *Client) bool {
    const owner = client.model.change_review.owner orelse return false;
    return resolveReviewPane(&client.model, owner) != null;
}

/// Example: `change_review.closeChangeReview(app);`
pub fn closeChangeReview(client: *Client) void {
    client.model.change_review.close();
}

/// Pins a query to copied provider session bytes before the view can change.
/// Example: `try change_review.sendRuntimeChangeReviewQuery(client, query);`
fn sendRuntimeChangeReviewQuery(client: *Client, query: core.QueryChangeReview) !void {
    try client.model.to_runtime.pushChangeReviewQuery(query);
}

/// Copies comment and path bytes before the originating editor can mutate them.
/// Example: `try change_review.sendRuntimeChangeReviewCommand(client, request);`
fn sendRuntimeChangeReviewCommand(client: *Client, request: core.ChangeReviewCommand) !void {
    try client.model.to_runtime.pushChangeReviewCommand(request);
}

/// Copies borrowed wire content before the next receive can overwrite it.
pub fn applyChangeReview(client: *Client, response: core.ChangeReviewSnapshotView) !bool {
    const continuation = client.model.request_lifecycle.tracker.take(response.request_id) orelse return false;
    const owner: data.ChangeReviewOperation = switch (continuation) {
        .change_review_query, .change_review_command => |owner| owner,
        .ignored => {
            retireChangeReview(client, response.request_id);
            return false;
        },
        else => return error.UnexpectedControlReply,
    };

    const accepted = applyChangeReviewResponse(client, owner, response) catch |err| {
        _ = failChangeReview(client, owner, @errorName(err));
        return false;
    };

    return accepted;
}

/// Retires a correlated reply after pane or tab removal without leaving a busy view.
pub fn retireChangeReview(client: *Client, request_id: core.RequestId) void {
    if (client.model.change_review.pending != request_id) {
        return;
    }

    const owner = client.model.change_review.owner orelse return;
    _ = failChangeReview(client, owner, "The pane was detached; reopen its review");
}

/// Opens any attached pane, including an agent launched in an ordinary terminal.
fn openChangeReviewSession(client: *Client, pane_id: core.PaneId) !void {
    const pane = findReviewPane(&client.model, pane_id) orelse return error.ChangeReviewPaneUnavailable;
    client.model.change_review.open(
        .{
            .pane_id = pane.id,
            .pane_generation = pane.pane_generation,
            .attachment_generation = pane.attachment_generation,
            .location = pane.location,
            .view_generation = 0,
            .edition_id = 0,
        },
    );
}

/// Captures the attached owner for a bounded, correlated request.
fn changeReviewOperation(client: *Client, edition_id: u64) !data.ChangeReviewOperation {
    if (client.model.change_review.session_changed) {
        return error.RetiredChangeReviewSession;
    }

    if (client.model.change_review.pending != null) {
        return error.ChangeReviewRequestPending;
    }

    var owner = client.model.change_review.owner orelse return error.ChangeReviewClosed;
    if (resolveReviewPane(&client.model, owner) == null) {
        return error.ChangeReviewPaneUnavailable;
    }

    owner.edition_id = edition_id;
    if (client.model.change_review.loaded) {
        try owner.setSession(client.model.change_review.snapshot.session);
    }

    return owner;
}

fn beginChangeReview(client: *Client, request_id: core.RequestId) void {
    client.model.change_review.begin(request_id);
}

/// Applies a reply only while both the attachment and view still exist.
fn applyChangeReviewResponse(client: *Client, owner: data.ChangeReviewOperation, response: core.ChangeReviewSnapshotView) !bool {
    if (resolveReviewPane(&client.model, owner) == null) {
        _ = failChangeReview(client, owner, "The pane was detached; reopen its review");
        return false;
    }

    return try client.model.change_review.apply(owner, response);
}

/// Retains pane availability even when its review is closed, and refreshes an open view.
pub fn changeReviewChanged(client: *Client, notification: core.ChangeReviewChanged) bool {
    const pane = findReviewPane(&client.model, notification.pane_id) orelse return false;
    const availability_changed = pane.applyChangeReview(notification);
    const review_changed = if (client.model.change_review.owner) |owner| resolveReviewPane(&client.model, owner) != null and client.model.change_review.changed(notification) else false;
    if (availability_changed) {
        client.model.pane_metadata_revision +%= 1;
    }

    return availability_changed or review_changed;
}

/// Retains review content and exposes failure without clearing adapter drafts.
pub fn failChangeReview(client: *Client, owner: data.ChangeReviewOperation, message: []const u8) bool {
    return client.model.change_review.failed(owner, message);
}

fn reportChangeReview(client: *Client, message: []const u8) void {
    client.model.change_review.report(message);
}

fn findReviewPane(model: *data.ClientModel, pane_id: core.PaneId) ?*data.Pane {
    const pane = model.panes.find(pane_id) orelse return null;
    return if (pane.attached and pane.pane_generation != 0) pane else null;
}

fn resolveReviewPane(model: *data.ClientModel, owner: data.ChangeReviewOperation) ?*const data.Pane {
    const pane = findReviewPane(model, owner.pane_id) orelse return null;
    return if (pane.pane_generation == owner.pane_generation and pane.attachment_generation == owner.attachment_generation) pane else null;
}

test "change review operation accepts terminal panes and rejects replaced attachments" {
    try attached_client_tests.rejectReplacedReviewAttachment(
        openChangeReviewSession,
        changeReviewOperation,
        applyChangeReviewResponse,
    );
}

test "change review operation updates closed review availability without opening or querying a view" {
    try attached_client_tests.retainReviewAvailability(openChangeReviewSession, changeReviewChanged);
}
