//! Correlated, bounded search turns. No worker borrows terminal state.

const client_connection = @import("client_connection.zig");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const PaneStore = @import("../pane/PaneStore.zig");
const PaneKey = @import("../pane/PaneKey.zig");
const Pane = @import("../pane/Pane.zig");
const core = @import("telar-core");
const Cursor = @import("../pane/Cursor.zig");
const std = @import("std");
const client_request = @import("client_request.zig");
const Wake = @import("events/Wake.zig");
const Matches = @import("delivery/Matches.zig");

/// Starts a search, replacing only this client's previous search.
/// Example: `try start(model, session, request);`.
pub fn start(model: *RuntimeModel, session: *Session, request: core.SearchPane) !void {
    const pane = resolveTarget(&model.panes, session, request.pane_id) orelse {
        return client_request.fail(session, request.request_id, .pane_not_found, "pane is not available for this search");
    };
    if (session.pending_search) |previous| {
        try fail(session, previous.request_id, "Pane search superseded");
    }

    session.pending_search = .{
        .request_id = request.request_id,
        .pane = pane,
        .cursor = Cursor.init(request.needle),
        .deadline_ns = std.Io.Clock.awake.now(model.io).nanoseconds + 250 * std.time.ns_per_ms,
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

    try completion.result;
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
    if (session.role != .control and session.attachments.find(pane.id) == null) {
        session.pending_search = null;
        try fail(session, wake.request_id, "Pane search target detached");
        return;
    }

    if (std.Io.Clock.awake.now(model.io).nanoseconds >= pending.deadline_ns) {
        session.pending_search = null;
        try fail(session, wake.request_id, "Pane search deadline exceeded; retry");
        return;
    }

    const complete = pending.cursor.advance(pane) catch {
        session.pending_search = null;
        try fail(session, wake.request_id, "Pane changed during search; retry");
        return;
    };
    if (complete) {
        const matches: Matches = .{
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
    } else {
        try schedule(model, wake, pane.ingest_pending);
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

fn resolveTarget(panes: *PaneStore, session: *Session, pane_id: core.PaneId) ?PaneKey {
    if (session.role == .control) {
        const pane = panes.findRunning(pane_id) orelse return null;
        if (pane.exit != null) {
            return null;
        }

        return pane.key();
    }

    const attachment = session.attachments.find(pane_id) orelse return null;
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
    session.attachments = .{};
    try std.testing.expect(resolveTarget(&panes, &session, pane.id) == null);
    session.role = .control;
    const selected = resolveTarget(&panes, &session, pane.id).?;
    try std.testing.expectEqual(@as(u64, 9), selected.generation);
    pane.generation = 10;
    try std.testing.expect(panes.resolve(selected) == null);
    try std.testing.expect(resolveTarget(&panes, &session, @enumFromInt(99)) == null);
}
