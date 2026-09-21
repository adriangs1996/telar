//! Runtime clients operations, reached from requests.dispatch.

const core = @import("telar-core");
const Application = @import("../Application.zig");
const PaneKeyType = @import("../../../pane/PaneKey.zig");
const ClientCommand = @import("telar-core").ClientCommand;
const DetachClient = @import("telar-core").DetachClient;
const QueryClients = @import("telar-core").QueryClients;
const Session = @import("../../client/Session.zig");
const RequestPaneFocusType = @import("telar-core").RequestPaneFocus;
const CompletePaneFocusType = @import("telar-core").CompletePaneFocus;
const RequestRuntimeStateType = @import("telar-core").RequestRuntimeState;
const ClientLayoutUpdateViewType = @import("telar-core").ClientLayoutUpdateView;
const std = @import("std");
const ClientKeyType = @import("../../../history/ClientKey.zig");
const RequestContext = @import("../RequestContext.zig");

/// Example: `try clients.routeRequestPaneFocus(request, focus);`.
pub fn routeRequestPaneFocus(request: *RequestContext, focus: RequestPaneFocusType) !void {
    try requestFocus(request.application, request.session, focus);
}

/// Example: `try clients.routeCompletePaneFocus(request, completion);`.
pub fn routeCompletePaneFocus(request: *RequestContext, completion: CompletePaneFocusType) !void {
    try completeFocus(request.application, request.session, completion);
}

/// Example: `try clients.routeRequestRuntimeState(request, runtime_state);`.
pub fn routeRequestRuntimeState(request: *RequestContext, runtime_state: RequestRuntimeStateType) !void {
    try request.session.delivery.requestRuntimeState(runtime_state.client_identity);
}

/// Example: `try clients.routeUpdateClientLayout(request, update);`.
pub fn routeUpdateClientLayout(request: *RequestContext, update: ClientLayoutUpdateViewType) !void {
    const identity = request.session.delivery.client_identity;
    if (identity == .invalid) {
        return error.ClientLayoutNotSubscribed;
    }

    try request.application.model.client_layouts.replace(.{
        .identity = identity,
        .layout = update,
        .sources = .{
            .panes = &request.application.model.panes,
            .workspaces = request.workspaces.reader(),
        },
    });
    request.application.noteSessionChange();
}

/// Example: `try clients.routeClientCommand(request, command);`.
pub fn routeClientCommand(request: *RequestContext, command: ClientCommand) !void {
    requestClientCommand(request, request.session, command) catch |err| {
        try request.session.delivery.responses.push(.{ .request_failed = .{
            .request_id = command.request_id,
            .code = .invalid_request,
            .message = @errorName(err),
        } });
    };
}

/// Example: `try clients.completeClientCommand(request, command);`.
pub fn completeClientCommand(request: *RequestContext, command: ClientCommand) !void {
    try finishClientCommand(request, request.session, command);
}

/// Example: `try clients.routeDetachClient(request, command);`.
pub fn routeDetachClient(request: *RequestContext, command: DetachClient) !void {
    if (request.session.role != .control or request.session.key.id == command.client_id) {
        return rejectDetachClient(request, command.request_id);
    }
    detachClient(request, .{ .id = command.client_id, .generation = command.client_generation }) catch {
        return rejectDetachClient(request, command.request_id);
    };
    try request.session.delivery.responses.push(.{ .request_completed = .{ .request_id = command.request_id } });
}

/// Example: `try clients.routeQueryClients(request, query);`.
pub fn routeQueryClients(request: *RequestContext, query: QueryClients) !void {
    var result = queryClients(request);
    result.request_id = query.request_id;
    try request.session.delivery.responses.push(.{ .client_list = result });
}

fn requestFocus(application: *Application, session: *Session, focus: RequestPaneFocusType) !void {
    if (session.role != .control) {
        return error.InvalidClientRole;
    }

    const source_key: PaneKeyType = .{
        .id = focus.pane_id,
        .generation = focus.pane_generation,
    };
    const pane = application.model.panes.resolve(source_key) orelse {
        try session.delivery.responses.push(.{ .request_failed = .{
            .request_id = focus.request_id,
            .code = .pane_not_found,
            .message = "pane not found or its generation is stale",
        } });
        session.delivery.close_after_reply = true;
        return;
    };
    if (pane.exit != null) {
        try session.delivery.responses.push(.{ .request_failed = .{
            .request_id = focus.request_id,
            .code = .pane_exited,
            .message = "pane already exited",
        } });
        session.delivery.close_after_reply = true;
        return;
    }
    if (session.pending_pane_focus != null) {
        try session.delivery.responses.push(.{ .request_failed = .{
            .request_id = focus.request_id,
            .code = .invalid_request,
            .message = "one pane focus request is already pending",
        } });
        session.delivery.close_after_reply = true;
        return;
    }

    const target = paneFocusOrigin(application, source_key) orelse {
        try session.delivery.responses.push(.{ .request_failed = .{
            .request_id = focus.request_id,
            .code = .invalid_request,
            .message = "no active UI client originated input for this pane",
        } });
        session.delivery.close_after_reply = true;
        return;
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
    try application.pump(target);
}

fn completeFocus(application: *Application, session: *Session, completion: CompletePaneFocusType) !void {
    if (session.role != .ui) {
        return error.InvalidClientRole;
    }

    const requester_key: ClientKeyType = .{
        .id = completion.requester.id,
        .generation = completion.requester.generation,
    };
    const requester = application.clients.resolve(requester_key) orelse return;
    if (requester.pending_pane_focus == null) {
        return;
    }

    if (requester.role != .control or !requester.acceptsFocusCompletion(session.key, completion)) {
        application.metrics.stale_client_messages += 1;
        return;
    }

    try requester.delivery.responses.push(.{ .pane_focus_result = .{
        .request_id = completion.request_id,
        .outcome = completion.outcome,
        .focused_pane_id = completion.focused_pane_id,
    } });
    requester.releaseFocus();
    requester.delivery.close_after_reply = true;
    try application.pump(requester);
}

fn paneFocusOrigin(application: *Application, pane_key: PaneKeyType) ?*Session {
    var found: ?*Session = null;
    var sequence: u64 = 0;
    for (&application.clients.items) |*slot| {
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

fn queryClients(request: *RequestContext) core.ClientList {
    var result: core.ClientList = .{ .request_id = .none };
    for (request.application.clients.items) |slot| {
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

    return result;
}

fn detachClient(request: *RequestContext, target: ClientKeyType) !void {
    const client = request.application.clients.resolve(target) orelse return error.ClientNotFound;
    if (client.closing or client.role != .ui or client.delivery.client_identity == .invalid) {
        return error.ClientNotFound;
    }

    request.application.dropClient(target);
}

fn rejectDetachClient(request: *RequestContext, request_id: core.RequestId) !void {
    try request.session.delivery.responses.push(.{ .request_failed = .{ .request_id = request_id, .code = .invalid_request, .message = "interactive client is absent, closing, or its generation is stale" } });
}

fn requestClientCommand(request: *RequestContext, session: *Session, command: core.ClientCommand) !void {
    if (session.role != .control or command.status != .request or session.pending_client_command != null) {
        return error.InvalidClientCommand;
    }

    const target = request.application.clients.resolve(.{ .id = command.route.id, .generation = command.route.generation }) orelse return error.ClientNotFound;
    if (target.closing or target.role != .ui or target.delivery.client_identity == .invalid) {
        return error.ClientNotFound;
    }

    var routed = command;
    routed.route = .{ .id = session.key.id, .generation = session.key.generation };
    session.pending_client_command = .{ .target = target.key, .request_id = command.request_id, .action = command.action, .target_id = command.target_id };
    errdefer session.pending_client_command = null;
    try target.delivery.responses.push(.{ .client_command = routed });
    try request.application.pump(target);
}

fn finishClientCommand(request: *RequestContext, session: *Session, completion: core.ClientCommand) !void {
    if (session.role != .ui) {
        return error.InvalidClientRole;
    }

    const requester = request.application.clients.resolve(.{ .id = completion.route.id, .generation = completion.route.generation }) orelse return;
    const pending = requester.pending_client_command orelse return;
    if (requester.closing or requester.role != .control or !pending.accepts(session.key, completion)) {
        return;
    }

    var reply = completion;
    reply.route = .{ .id = session.key.id, .generation = session.key.generation };
    try requester.delivery.responses.push(.{ .client_command_result = reply });
    requester.pending_client_command = null;
    try request.application.pump(requester);
}
