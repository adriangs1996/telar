//! Change review: opens a review of an agent's changes, queries its patch and
//! sends its comments.
const data = @import("model");
const core = @import("telar-core");
const attached_client_tests = @import("../attached_client_tests.zig");
const Client = @import("../AttachedClient.zig");

/// Opens the latest review for any attached pane, preserving an already open edition.
/// Example: `try change_review.openChangeReview(app, pane_id);`
pub fn openChangeReview(model: *data.ClientModel, pane_id: core.PaneId) !void {
    try openChangeReviewSession(model, pane_id);
    try queryChangeReview(model, if (model.change_review.loaded) model.change_review.snapshot.edition_id else 0);
}

/// Zero requests latest; explicit navigation never replaces a review on new edits.
/// Example: `try change_review.queryChangeReview(app, edition_id);`
pub fn queryChangeReview(model: *data.ClientModel, edition_id: u64) !void {
    const owner = changeReviewOperation(model, edition_id) catch |err| {
        reportChangeReview(model, @errorName(err));
        return err;
    };

    const request_id = try model.request_lifecycle.nextId();
    try model.request_lifecycle.tracker.add(
        request_id,
        .{
            .change_review_query = owner,
        },
    );
    beginChangeReview(model, request_id);
    sendRuntimeChangeReviewQuery(
        model,
        .{
            .request_id = request_id,
            .pane_id = owner.pane_id,
            .pane_generation = owner.pane_generation,
            .edition_id = edition_id,
            .session = owner.sessionSlice(),
        },
    ) catch |err| {
        _ = model.request_lifecycle.tracker.take(request_id);
        _ = failChangeReview(model, owner, @errorName(err));
        return err;
    };
}

/// Sends one mutation while retaining both the canonical snapshot and local draft.
/// Pass the displayed edition and revision to bind a delayed gesture to its owner.
/// Example: `try change_review.commandChangeReview(app, request);`
pub fn commandChangeReview(model: *data.ClientModel, request: core.ChangeReviewCommand) !void {
    if (!model.change_review.loaded) {
        reportChangeReview(model, "No change review is loaded");
        return error.ChangeReviewNotLoaded;
    }

    const edition_id = if (request.edition_id == 0) model.change_review.snapshot.edition_id else request.edition_id;
    const owner = changeReviewOperation(model, edition_id) catch |err| {
        reportChangeReview(model, @errorName(err));
        return err;
    };

    var outgoing = request;
    outgoing.request_id = try model.request_lifecycle.nextId();
    outgoing.pane_id = owner.pane_id;
    outgoing.pane_generation = owner.pane_generation;
    outgoing.edition_id = edition_id;
    outgoing.session = owner.sessionSlice();
    if (outgoing.expected_revision == 0) {
        outgoing.expected_revision = model.change_review.snapshot.revision;
    }

    try model.request_lifecycle.tracker.add(
        outgoing.request_id,
        .{
            .change_review_command = owner,
        },
    );
    beginChangeReview(model, outgoing.request_id);
    sendRuntimeChangeReviewCommand(model, outgoing) catch |err| {
        _ = model.request_lifecycle.tracker.take(outgoing.request_id);
        _ = failChangeReview(model, owner, @errorName(err));
        return err;
    };
}

/// Drains notices after the view consumes mutation success or failure, so a later
/// refresh can never be mistaken for the acknowledgement of an earlier save.
/// Example: `change_review.refreshChangeReview(app);`
pub fn refreshChangeReview(model: *data.ClientModel) void {
    if (model.change_review.needsRefresh() and model.change_review.errorSlice().len == 0) {
        queryChangeReview(model, if (model.change_review.loaded) model.change_review.snapshot.edition_id else 0) catch {};
    }
}

/// Resolves the review owner without retaining an address across lifecycle changes.
/// Example: `_ = change_review.isChangeReviewAttached(app);`
pub fn isChangeReviewAttached(model: *data.ClientModel) bool {
    const owner = model.change_review.owner orelse return false;
    return resolveReviewPane(model, owner) != null;
}

/// Example: `change_review.closeChangeReview(app);`
pub fn closeChangeReview(model: *data.ClientModel) void {
    model.change_review.close();
}

/// Pins a query to copied provider session bytes before the view can change.
/// Example: `try change_review.sendRuntimeChangeReviewQuery(client, query);`
fn sendRuntimeChangeReviewQuery(model: *data.ClientModel, query: core.QueryChangeReview) !void {
    try model.to_runtime.pushChangeReviewQuery(query);
}

/// Copies comment and path bytes before the originating editor can mutate them.
/// Example: `try change_review.sendRuntimeChangeReviewCommand(client, request);`
fn sendRuntimeChangeReviewCommand(model: *data.ClientModel, request: core.ChangeReviewCommand) !void {
    try model.to_runtime.pushChangeReviewCommand(request);
}

/// Copies borrowed wire content before the next receive can overwrite it.
pub fn applyChangeReview(model: *data.ClientModel, response: core.ChangeReviewSnapshotView) !bool {
    const continuation = model.request_lifecycle.tracker.take(response.request_id) orelse return false;
    const owner: data.ChangeReviewOperation = switch (continuation) {
        .change_review_query, .change_review_command => |owner| owner,
        .ignored => {
            retireChangeReview(model, response.request_id);
            return false;
        },
        else => return error.UnexpectedControlReply,
    };

    const accepted = applyChangeReviewResponse(model, owner, response) catch |err| {
        _ = failChangeReview(model, owner, @errorName(err));
        return false;
    };

    return accepted;
}

/// Retires a correlated reply after pane or tab removal without leaving a busy view.
pub fn retireChangeReview(model: *data.ClientModel, request_id: core.RequestId) void {
    if (model.change_review.pending != request_id) {
        return;
    }

    const owner = model.change_review.owner orelse return;
    _ = failChangeReview(model, owner, "The pane was detached; reopen its review");
}

/// Opens any attached pane, including an agent launched in an ordinary terminal.
fn openChangeReviewSession(model: *data.ClientModel, pane_id: core.PaneId) !void {
    const pane = findReviewPane(model, pane_id) orelse return error.ChangeReviewPaneUnavailable;
    model.change_review.open(
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
fn changeReviewOperation(model: *data.ClientModel, edition_id: u64) !data.ChangeReviewOperation {
    if (model.change_review.session_changed) {
        return error.RetiredChangeReviewSession;
    }

    if (model.change_review.pending != null) {
        return error.ChangeReviewRequestPending;
    }

    var owner = model.change_review.owner orelse return error.ChangeReviewClosed;
    if (resolveReviewPane(model, owner) == null) {
        return error.ChangeReviewPaneUnavailable;
    }

    owner.edition_id = edition_id;
    if (model.change_review.loaded) {
        try owner.setSession(model.change_review.snapshot.session);
    }

    return owner;
}

fn beginChangeReview(model: *data.ClientModel, request_id: core.RequestId) void {
    model.change_review.begin(request_id);
}

/// Applies a reply only while both the attachment and view still exist.
fn applyChangeReviewResponse(model: *data.ClientModel, owner: data.ChangeReviewOperation, response: core.ChangeReviewSnapshotView) !bool {
    if (resolveReviewPane(model, owner) == null) {
        _ = failChangeReview(model, owner, "The pane was detached; reopen its review");
        return false;
    }

    return try model.change_review.apply(owner, response);
}

/// Retains pane availability even when its review is closed, and refreshes an open view.
pub fn changeReviewChanged(model: *data.ClientModel, notification: core.ChangeReviewChanged) bool {
    const pane = findReviewPane(model, notification.pane_id) orelse return false;
    const availability_changed = pane.applyChangeReview(notification);
    const review_changed = if (model.change_review.owner) |owner| resolveReviewPane(model, owner) != null and model.change_review.changed(notification) else false;
    if (availability_changed) {
        model.pane_metadata_revision +%= 1;
    }

    return availability_changed or review_changed;
}

/// Retains review content and exposes failure without clearing adapter drafts.
pub fn failChangeReview(model: *data.ClientModel, owner: data.ChangeReviewOperation, message: []const u8) bool {
    return model.change_review.failed(owner, message);
}

fn reportChangeReview(model: *data.ClientModel, message: []const u8) void {
    model.change_review.report(message);
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
