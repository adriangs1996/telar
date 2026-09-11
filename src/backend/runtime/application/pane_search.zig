//! Correlated, bounded search turns. No worker borrows terminal state.

const SearchPaneType = @import("telar-core").SearchPane;
const Cursor = @import("../../pane/Cursor.zig");
const std = @import("std");
const Wake = @import("Wake.zig");
const MatchesType = @import("commands/Matches.zig");
const RequestIdType = @import("telar-core").RequestId;

/// Starts a search, replacing only this client's previous search.
/// Example: `try start(application, session, request);`.
pub fn start(application: anytype, session: anytype, request: SearchPaneType) !void {
    const attachment = session.attachments.find(request.pane_id) orelse {
        try session.delivery.responses.push(.{ .request_failed = .{
            .request_id = request.request_id,
            .code = .pane_not_found,
            .message = "pane is not attached",
        } });
        return;
    };
    if (session.pending_search) |previous| {
        try fail(session, previous.request_id, "Pane search superseded");
    }

    session.pending_search = .{
        .request_id = request.request_id,
        .pane = attachment.pane.key(),
        .cursor = Cursor.init(request.needle),
        .deadline_ns = std.Io.Clock.awake.now(application.io).nanoseconds + 250 * std.time.ns_per_ms,
    };
    if (session.search_scheduled) {
        return;
    }

    errdefer session.pending_search = null;
    try schedule(application, .{ .client = session.key, .request_id = request.request_id }, false);
}

/// Resolves ownership again before inspecting at most one row budget.
/// Example: `try advance(application, wake);`.
pub fn advance(application: anytype, completion: Wake) !void {
    try completion.result;
    const session = application.clients.resolve(completion.client) orelse return;
    session.search_scheduled = false;
    if (!session.active()) {
        return;
    }
    const pending = if (session.pending_search) |*pending| pending else return;
    const wake: Wake = .{ .client = completion.client, .request_id = pending.request_id };

    const pane = application.model.panes.resolve(pending.pane) orelse {
        session.pending_search = null;
        try fail(session, wake.request_id, "Pane search target exited");
        try application.pump(session);
        return;
    };
    if (session.attachments.find(pane.id) == null) {
        session.pending_search = null;
        try fail(session, wake.request_id, "Pane search target detached");
        try application.pump(session);
        return;
    }

    if (std.Io.Clock.awake.now(application.io).nanoseconds >= pending.deadline_ns) {
        session.pending_search = null;
        try fail(session, wake.request_id, "Pane search deadline exceeded; retry");
        try application.pump(session);
        return;
    }

    const complete = pending.cursor.advance(pane) catch {
        session.pending_search = null;
        try fail(session, wake.request_id, "Pane changed during search; retry");
        try application.pump(session);
        return;
    };
    if (complete) {
        const matches: MatchesType = .{
            .items = pending.cursor.matches,
            .count = pending.cursor.count,
            .truncated = pending.cursor.truncated,
        };
        session.pending_search = null;
        try session.delivery.responses.push(.{ .pane_matches = .{
            .request_id = wake.request_id,
            .pane_id = pane.id,
            .matches = matches,
        } });
        try application.pump(session);
    } else {
        try schedule(application, wake, pane.ingest_pending);
    }
}

fn fail(session: anytype, request_id: RequestIdType, message: []const u8) !void {
    try session.delivery.responses.push(.{ .request_failed = .{
        .request_id = request_id,
        .code = .resource_limit,
        .message = message,
    } });
}

fn schedule(application: anytype, wake: Wake, busy: bool) !void {
    const session = application.clients.resolve(wake.client) orelse return;
    std.debug.assert(!session.search_scheduled);
    session.search_scheduled = true;
    errdefer session.search_scheduled = false;

    try application.select.concurrent(.pane_search, yield, .{ application.io, wake, busy });
}

fn yield(io: std.Io, wake: Wake, busy: bool) Wake {
    var result = wake;
    if (busy) {
        result.result = io.sleep(.fromMilliseconds(1), .awake);
    }

    return result;
}
