//! Correlated, bounded search turns. No worker borrows terminal state.

const client_connection = @import("client_connection.zig");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const Attachments = @import("attachment/Attachments.zig");
const PaneStore = @import("../pane/PaneStore.zig");
const PaneKey = @import("../pane/PaneKey.zig");
const Pane = @import("../pane/Pane.zig");
const core = @import("telar-core");
const text_search = @import("../pane/text_search.zig");
const Cursor = text_search.Search;
const limit_reached = @import("limit_reached.zig");
const std = @import("std");
const client_request = @import("client_request.zig");
const Wake = @import("events/Wake.zig");
const Matches = @import("delivery/Matches.zig");

/// Starts a search, replacing only this client's previous search.
/// Example: `try start(model, session, request);`.
pub fn start(model: *RuntimeModel, session: *Session, request: core.SearchPane) !void {
    const pane = resolveTarget(&model.panes, &model.attachments, session, request.pane_id) orelse {
        return client_request.fail(session, request.request_id, .pane_not_found, "pane is not available for this search");
    };
    if (session.pending_search) |previous| {
        try fail(session, previous.request_id, "Pane search superseded");
    }

    session.pending_search = .{
        .request_id = request.request_id,
        .pane = pane,
        .cursor = Cursor.init(request.needle),
        .deadline_ns = std.Io.Clock.awake.now(model.io).nanoseconds + text_search.deadline_ns,
    };
    if (session.search_scheduled) {
        return;
    }

    errdefer session.pending_search = null;
    try schedule(model, .{ .client = session.key, .request_id = request.request_id }, false);
}

/// Resolves ownership again before inspecting at most one row budget.
/// Example: `try advance(model, wake);`.
pub fn advance(model: *RuntimeModel, completion: Wake) !void {
    const session = model.clients.resolve(completion.client) orelse return;
    session.search_scheduled = false;
    if (session.closing) {
        client_connection.finalize(model, completion.client);
        return;
    }

    // A wake that failed still owes its search an answer.
    completion.result catch |err| {
        if (session.pending_search) |pending| {
            session.pending_search = null;
            fail(session, pending.request_id, "Pane search stopped; retry") catch {};
        }

        return err;
    };

    if (!session.active()) {
        return;
    }
    const pending = if (session.pending_search) |*pending| pending else return;
    const wake: Wake = .{ .client = completion.client, .request_id = pending.request_id };

    const pane = model.panes.resolve(pending.pane) orelse {
        session.pending_search = null;
        try fail(session, wake.request_id, "Pane search target exited");
        return;
    };
    if (session.role != .control and model.attachments.find(session.slot, pane.id) == null) {
        session.pending_search = null;
        try fail(session, wake.request_id, "Pane search target detached");
        return;
    }

    const expired = std.Io.Clock.awake.now(model.io).nanoseconds >= pending.deadline_ns;
    const complete = expired or pending.cursor.advance(pane) catch {
        session.pending_search = null;
        try fail(session, wake.request_id, "Pane changed during search; retry");
        return;
    };
    if (!complete) {
        return schedule(model, wake, pane.ingest_pending);
    }

    // A search out of time answers with the newest matches it reached.
    var matches: Matches = .{
        .truncated = pending.cursor.truncated or expired,
    };
    matches.count = @intCast(pending.cursor.ordered(&matches.items).len);
    reportLimits(model, &pending.cursor, expired);
    session.pending_search = null;
    try session.delivery.responses.push(.{ .pane_matches = .{
        .request_id = wake.request_id,
        .pane_id = pane.id,
        .matches = matches,
    } });
}

fn reportLimits(model: *RuntimeModel, cursor: *const Cursor, expired: bool) void {
    if (cursor.matches_cut) {
        limit_reached.report(model, .{
            .limit = text_search.matches_limit,
        });
    }

    if (cursor.rows_cut and !cursor.matches_cut) {
        limit_reached.report(model, .{
            .limit = text_search.rows_limit,
        });
    }

    if (cursor.columns_cut) {
        limit_reached.report(model, .{
            .limit = text_search.columns_limit,
        });
    }

    if (expired) {
        limit_reached.report(model, .{
            .limit = text_search.deadline_limit,
        });
    }
}

fn fail(session: *Session, request_id: core.RequestId, message: []const u8) !void {
    try client_request.fail(session, request_id, .resource_limit, message);
}

fn schedule(model: *RuntimeModel, wake: Wake, busy: bool) !void {
    const session = model.clients.resolve(wake.client) orelse return;
    std.debug.assert(!session.search_scheduled);
    session.search_scheduled = true;
    errdefer session.search_scheduled = false;

    try model.select.concurrent(.pane_search, yield, .{ model.io, wake, busy });
}

fn yield(io: std.Io, wake: Wake, busy: bool) Wake {
    var result = wake;
    if (busy) {
        result.result = io.sleep(.fromMilliseconds(1), .awake);
    }

    return result;
}

fn resolveTarget(panes: *PaneStore, attachments: *Attachments, session: *Session, pane_id: core.PaneId) ?PaneKey {
    if (session.role == .control) {
        const pane = panes.findRunning(pane_id) orelse return null;
        if (pane.exit != null) {
            return null;
        }

        return pane.key();
    }

    const attachment = attachments.find(session.slot, pane_id) orelse return null;
    return attachment.pane.key();
}

test "headless searches capture a generation without granting UI attachment authority" {
    const pane = try std.testing.allocator.create(Pane);
    defer std.testing.allocator.destroy(pane);
    pane.id = @enumFromInt(7);
    pane.generation = 9;
    pane.launch_state = .running;
    pane.exit = null;
    var panes: PaneStore = .{};
    panes.items[0] = pane;
    panes.count = 1;
    panes.index.put(7, 0);
    var session: Session = undefined;
    session.role = .ui;
    session.slot = 0;
    var attachments: Attachments = .{};
    try std.testing.expect(resolveTarget(&panes, &attachments, &session, pane.id) == null);
    session.role = .control;
    const selected = resolveTarget(&panes, &attachments, &session, pane.id).?;
    try std.testing.expectEqual(@as(u64, 9), selected.generation);
    pane.generation = 10;
    try std.testing.expect(panes.resolve(selected) == null);
    try std.testing.expect(resolveTarget(&panes, &attachments, &session, @enumFromInt(99)) == null);
}
