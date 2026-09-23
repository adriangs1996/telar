//! A control client lists interactive clients, detaches one, or asks one to
//! run a client command or focus a pane. The interactive client answers and
//! the runtime correlates the answer with the waiting control client.

const client_connection = @import("client_connection.zig");
const core = @import("telar-core");
const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const ClientKey = @import("../history/ClientKey.zig");
const PaneKey = @import("../pane/PaneKey.zig");
const client_request = @import("client_request.zig");

/// Routes a control client's command to one interactive client.
///
/// ```zig
/// try client_control.requestCommand(model, session, command);
/// ```
pub fn requestCommand(model: *RuntimeModel, session: *Session, command: core.ClientCommand) !void {
    forwardCommand(model, session, command) catch |err| {
        try client_request.fail(session, command.request_id, .invalid_request, @errorName(err));
    };
}

/// Returns an interactive client's command result to the control client
/// that is waiting for exactly this exchange.
///
/// ```zig
/// try client_control.finishCommand(model, session, completion);
/// ```
pub fn finishCommand(model: *RuntimeModel, session: *Session, completion: core.ClientCommand) !void {
    if (session.role != .ui) {
        return error.InvalidClientRole;
    }

    const requester = model.clients.resolve(.{ .id = completion.route.id, .generation = completion.route.generation }) orelse return;
    const pending = requester.pending_client_command orelse return;
    if (requester.closing or requester.role != .control or !pending.accepts(session.key, completion)) {
        return;
    }

    var reply = completion;
    reply.route = .{ .id = session.key.id, .generation = session.key.generation };
    try requester.delivery.responses.push(.{ .client_command_result = reply });
    requester.pending_client_command = null;
}

/// Drops one interactive client on behalf of a control client.
///
/// ```zig
/// try client_control.detach(model, session, request);
/// ```
pub fn detach(model: *RuntimeModel, session: *Session, request: core.DetachClient) !void {
    if (session.role != .control or session.key.id == request.client_id) {
        return rejectDetach(session, request.request_id);
    }

    const target: ClientKey = .{ .id = request.client_id, .generation = request.client_generation };
    const client = model.clients.resolve(target) orelse return rejectDetach(session, request.request_id);
    if (client.closing or client.role != .ui or client.delivery.client_identity == .invalid) {
        return rejectDetach(session, request.request_id);
    }

    client_connection.drop(model, target);
    try client_request.complete(session, request.request_id);
}

/// Replies with every subscribed interactive client.
///
/// ```zig
/// try client_control.list(model, session, query);
/// ```
pub fn list(model: *RuntimeModel, session: *Session, query: core.QueryClients) !void {
    var result: core.ClientList = .{ .request_id = query.request_id };
    for (model.clients.items) |slot| {
        const client = slot orelse continue;
        if (client.closing or client.role != .ui or client.delivery.client_identity == .invalid) {
            continue;
        }

        result.entries[result.count] = .{
            .id = client.key.id,
            .generation = client.key.generation,
            .identity = @intFromEnum(client.delivery.client_identity),
            .attachments = @intCast(client.attachments.count),
            .last_input_pane = core.raw(client.last_input_pane),
            .last_input_sequence = client.last_input_sequence,
        };
        result.count += 1;
    }

    try session.delivery.responses.push(.{ .client_list = result });
}

/// Asks the interactive client that last typed into a pane to focus it.
///
/// ```zig
/// try client_control.requestFocus(model, session, focus);
/// ```
pub fn requestFocus(model: *RuntimeModel, session: *Session, focus: core.RequestPaneFocus) !void {
    if (session.role != .control) {
        return error.InvalidClientRole;
    }

    const source_key: PaneKey = .{ .id = focus.pane_id, .generation = focus.pane_generation };
    const pane = model.panes.resolve(source_key) orelse {
        return rejectFocus(session, focus.request_id, .pane_not_found, "pane not found or its generation is stale");
    };

    if (pane.exit != null) {
        return rejectFocus(session, focus.request_id, .pane_exited, "pane already exited");
    }

    if (session.pending_pane_focus != null) {
        return rejectFocus(session, focus.request_id, .invalid_request, "one pane focus request is already pending");
    }

    const target = focusOrigin(model, source_key) orelse {
        return rejectFocus(session, focus.request_id, .invalid_request, "no active UI client originated input for this pane");
    };
    try session.reserveFocus(.{
        .request_id = focus.request_id,
        .pane_id = focus.pane_id,
        .pane_generation = focus.pane_generation,
        .target = target.key,
    });
    target.delivery.responses.push(.{ .pane_focus_command = .{
        .requester = .{ .id = session.key.id, .generation = session.key.generation },
        .request_id = focus.request_id,
        .pane_id = focus.pane_id,
        .pane_generation = focus.pane_generation,
        .direction = focus.direction,
    } }) catch |err| {
        session.releaseFocus();
        return err;
    };
}

/// Returns the interactive client's focus outcome to its control client.
///
/// ```zig
/// try client_control.finishFocus(model, session, completion);
/// ```
pub fn finishFocus(model: *RuntimeModel, session: *Session, completion: core.CompletePaneFocus) !void {
    if (session.role != .ui) {
        return error.InvalidClientRole;
    }

    const requester_key: ClientKey = .{ .id = completion.requester.id, .generation = completion.requester.generation };
    const requester = model.clients.resolve(requester_key) orelse return;
    if (requester.pending_pane_focus == null) {
        return;
    }

    if (requester.role != .control or !requester.acceptsFocusCompletion(session.key, completion)) {
        model.metrics.stale_client_messages += 1;
        return;
    }

    try requester.delivery.responses.push(.{ .pane_focus_result = .{
        .request_id = completion.request_id,
        .outcome = completion.outcome,
        .focused_pane_id = completion.focused_pane_id,
    } });
    requester.releaseFocus();
    requester.delivery.close_after_reply = true;
}

/// Fails every command and focus exchange that waits on a departing client.
///
/// ```zig
/// client_control.abandon(model, departed_key);
/// ```
pub fn abandon(model: *RuntimeModel, key: ClientKey) void {
    for (model.clients.items) |slot| {
        const requester = slot orelse continue;
        const pending = requester.pending_client_command orelse continue;
        if (!std.meta.eql(pending.target, key)) {
            continue;
        }

        requester.pending_client_command = null;
        client_request.fail(requester, pending.request_id, .invalid_request, "target client disconnected before confirming the operation") catch {
            client_connection.drop(model, requester.key);
        };
    }

    for (&model.clients.items) |*slot| {
        const requester = slot.* orelse continue;
        const pending = requester.pending_pane_focus orelse continue;

        if (!std.meta.eql(pending.target, key)) {
            continue;
        }

        requester.releaseFocus();
        client_request.fail(requester, pending.request_id, .invalid_request, "focus client disconnected") catch {
            client_connection.drop(model, requester.key);
            continue;
        };
        requester.delivery.close_after_reply = true;
    }
}

fn forwardCommand(model: *RuntimeModel, session: *Session, command: core.ClientCommand) !void {
    if (session.role != .control or command.status != .request or session.pending_client_command != null) {
        return error.InvalidClientCommand;
    }

    const target = model.clients.resolve(.{ .id = command.route.id, .generation = command.route.generation }) orelse return error.ClientNotFound;
    if (target.closing or target.role != .ui or target.delivery.client_identity == .invalid) {
        return error.ClientNotFound;
    }

    var routed = command;
    routed.route = .{ .id = session.key.id, .generation = session.key.generation };
    session.pending_client_command = .{ .target = target.key, .request_id = command.request_id, .action = command.action, .target_id = command.target_id };
    errdefer session.pending_client_command = null;
    try target.delivery.responses.push(.{ .client_command = routed });
}

fn focusOrigin(model: *RuntimeModel, pane_key: PaneKey) ?*Session {
    var found: ?*Session = null;
    var sequence: u64 = 0;
    for (&model.clients.items) |*slot| {
        const client = slot.* orelse continue;
        if (!client.active() or client.role != .ui or client.last_input_pane != pane_key.id or
            client.last_input_sequence <= sequence)
        {
            continue;
        }

        const attachment = client.attachments.find(pane_key.id) orelse continue;
        if (!std.meta.eql(attachment.pane.key(), pane_key)) {
            continue;
        }

        found = client;
        sequence = client.last_input_sequence;
    }

    return found;
}

fn rejectFocus(session: *Session, request_id: core.RequestId, code: core.FailureCode, message: []const u8) !void {
    try client_request.fail(session, request_id, code, message);
    session.delivery.close_after_reply = true;
}

fn rejectDetach(session: *Session, request_id: core.RequestId) !void {
    try client_request.fail(session, request_id, .invalid_request, "interactive client is absent, closing, or its generation is stale");
}
