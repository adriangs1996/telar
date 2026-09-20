//! Correlates review requests; the application handler owns replica mutations.
const core = @import("telar-core");
const Client = @import("../../AttachedClient.zig");
const Handler = @import("../../application/change_review/Handler.zig");
const Operation = @import("../../connection/ChangeReviewOperation.zig");
const lifecycle = @import("../../connection/request_lifecycle.zig");
const runtime_io = @import("../../entrypoints/runtime_io.zig");

/// Opens the latest review for any attached pane, preserving an already open edition.
/// Example: `try change_review.open(client, pane_id);`
pub fn open(client: *Client, pane_id: core.PaneId) !void {
    try handler(client).open(pane_id);
    try query(client, if (client.change_review.loaded) client.change_review.snapshot.edition_id else 0);
}

/// Reports whether the pane and attachment displayed by the review still exist.
/// Example: `if (!change_review.isAttached(client)) closeReview();`
pub fn isAttached(client: *Client) bool {
    return handler(client).isAttached();
}

/// Example: `change_review.close(client);`
pub fn close(client: *Client) void {
    handler(client).close();
}

/// Zero requests latest; explicit navigation never replaces a review on new edits.
/// Example: `try change_review.query(client, snapshot.next_edition_id);`
pub fn query(client: *Client, edition_id: u64) !void {
    const use_case = handler(client);
    const owner = use_case.operation(edition_id) catch |err| {
        use_case.report(@errorName(err));
        return err;
    };
    const request_id = try lifecycle.nextId(client);
    try lifecycle.register(client, .{ .request_id = request_id, .continuation = .{ .change_review_query = owner } });
    use_case.begin(request_id);
    runtime_io.enqueueChangeReviewQuery(client, .{ .request_id = request_id, .pane_id = owner.pane_id, .pane_generation = owner.pane_generation, .edition_id = edition_id, .session = owner.sessionSlice() }) catch |err| {
        _ = lifecycle.consume(client, request_id);
        _ = use_case.failed(owner, @errorName(err));
        return err;
    };
}

/// Sends one mutation while retaining both the canonical snapshot and local draft.
/// Pass the displayed edition and revision to bind a delayed gesture to its owner.
/// Example: `try change_review.command(client, request);`
pub fn command(client: *Client, request: core.ChangeReviewCommand) !void {
    const use_case = handler(client);
    if (!client.change_review.loaded) {
        use_case.report("No change review is loaded");
        return error.ChangeReviewNotLoaded;
    }
    const edition_id = if (request.edition_id == 0) client.change_review.snapshot.edition_id else request.edition_id;
    const owner = use_case.operation(edition_id) catch |err| {
        use_case.report(@errorName(err));
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
    use_case.begin(outgoing.request_id);
    runtime_io.enqueueChangeReviewCommand(client, outgoing) catch |err| {
        _ = lifecycle.consume(client, outgoing.request_id);
        _ = use_case.failed(owner, @errorName(err));
        return err;
    };
}

/// Copies borrowed wire content before the next receive can overwrite it.
/// Example: `_ = try change_review.apply(client, response);`
pub fn apply(client: *Client, response: core.ChangeReviewSnapshotView) !bool {
    const continuation = lifecycle.consume(client, response.request_id) orelse return false;
    const owner: Operation = switch (continuation) {
        .change_review_query, .change_review_command => |operation| operation,
        .ignored => {
            retired(client, response.request_id);
            return false;
        },
        else => return error.UnexpectedControlReply,
    };
    const use_case = handler(client);
    const accepted = use_case.apply(owner, response) catch |err| {
        _ = use_case.failed(owner, @errorName(err));
        return false;
    };
    return accepted;
}

/// Refreshes metadata on the same immutable edition, coalescing notices while busy.
/// Example: `_ = change_review.changed(client, notification);`
pub fn changed(client: *Client, notification: core.ChangeReviewChanged) bool {
    const accepted = handler(client).changed(notification);
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

/// Applies a previously correlated runtime rejection.
/// Example: `_ = change_review.failed(client, operation, failure.message);`
pub fn failed(client: *Client, operation: Operation, message: []const u8) bool {
    return handler(client).failed(operation, message);
}

/// Retires a correlated reply after pane or tab removal without leaving a busy view.
/// Example: `change_review.retired(client, request_id);`
pub fn retired(client: *Client, request_id: core.RequestId) void {
    if (client.change_review.pending != request_id) {
        return;
    }
    const owner = client.change_review.owner orelse return;
    _ = handler(client).failed(owner, "The pane was detached; reopen its review");
}

fn handler(client: *Client) Handler {
    return .{ .model = &client.model, .session = &client.change_review };
}
