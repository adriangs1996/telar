//! Runtime panes operations, reached from requests.dispatch.

const core = @import("telar-core");
const Application = @import("../Application.zig");
const PaneResize = @import("../commands/PaneResize.zig");
const pane_resize = @import("../commands/pane_resize.zig");
const AcknowledgeFrame = @import("../commands/AcknowledgeFrame.zig");
const frame_ack = @import("../commands/frame_ack.zig");
const RequestCellSnapshot = @import("../commands/RequestCellSnapshot.zig");
const request_snapshot = @import("../commands/request_snapshot.zig");
const SetPaneViewport = @import("../commands/SetPaneViewport.zig");
const pane_viewport = @import("../commands/pane_viewport.zig");
const SendPaneText = @import("../commands/SendPaneText.zig");
const send_pane_text = @import("../commands/send_pane_text.zig");
const PendingFailureType = @import("../../delivery/PendingFailure.zig");
const CopySelection = @import("../commands/CopySelection.zig");
const copy_selection = @import("../commands/copy_selection.zig");
const selection_policy = @import("../../attachment/selection.zig");
const pane_mod = @import("../../../pane/pane_namespace.zig");
const OpenPane = @import("../commands/OpenPane.zig");
const OpenPaneResult = @import("../commands/OpenPaneResult.zig");
const Proposal = @import("../../../workspace/Proposal.zig");
const OpenPaneFailure = @import("../../entrypoints/requests/OpenPaneFailure.zig");
const CreatePane = @import("../commands/CreatePane.zig");
const create_pane = @import("../commands/create_pane.zig");
const CreatePaneFailure = @import("../../entrypoints/requests/CreatePaneFailure.zig");
const DetachPane = @import("../commands/DetachPane.zig");
const detach_pane = @import("../commands/detach_pane.zig");
const Session = @import("../../client/Session.zig");
const std = @import("std");
const pane_search = @import("../pane_search.zig");
const PaneType = @import("../../../pane/Pane.zig");
const PaneLaunchedType = @import("../../../pane/PaneLaunched.zig");
const launch_cwd_module = @import("../../client/launch_cwd.zig");
const open_pane_commands = @import("../commands/open_pane.zig");
const RequestContext = @import("../RequestContext.zig");
const events = @import("../events.zig");

/// Example: `try panes.routeOpenPane(request, wire);`.
pub fn routeOpenPane(request: *RequestContext, wire: core.OpenPaneView) !void {
    const result = openPane(request, .{
        .target = wire.target,
        .size = wire.size,
        .launch = wire.launch,
    }) catch |err| {
        const failure: OpenPaneFailure = switch (err) {
            error.PaneNotFound => .{ .code = .pane_not_found, .message = "pane not found" },
            error.WorkspaceNotFound => .{ .code = .workspace_not_found, .message = "workspace not found" },
            error.WorkspaceHasNoPane => .{ .code = .pane_not_found, .message = "workspace has no running pane" },
            error.InvalidOpenRequest => .{ .code = .invalid_request, .message = "default pane launch is missing" },
            error.InvalidLaunchCwd => .{ .code = .invalid_request, .message = "cwd source pane is unavailable" },
            error.WorkspaceCreateFailed => .{ .code = .resource_limit, .message = "could not create workspace" },
            error.GeometryUnavailable => .{ .code = .resource_limit, .message = "workspace geometry is leased by another client" },
            error.PaneLimitReached => .{ .code = .resource_limit, .message = "pane limit reached" },
            error.UnsupportedEnvironment => .{ .code = .invalid_request, .message = "custom pane environment is not supported" },
            error.PaneSpawnFailed => .{ .code = .spawn_failed, .message = "could not start pane process" },
            error.PaneResizeFailed => .{ .code = .internal, .message = "could not resize pane" },
            else => return err,
        };

        try openPaneQueueFailure(request, wire.request_id, failure);
        return;
    };

    try request.session.delivery.responses.push(.{ .pane_opened = .{
        .request_id = wire.request_id,
        .pane_id = result.pane.key.id,
        .pane_generation = result.pane.key.generation,
        .kind = result.pane.kind,
        .location = result.pane.location,
        .created = result.created,
    } });
}

/// Example: `try panes.routePaneInput(request, input);`.
pub fn routePaneInput(request: *RequestContext, input: core.PaneInput) !void {
    const attachment = request.session.attachments.find(input.pane_id) orelse {
        request.application.metrics.stale_client_messages += 1;
        return;
    };
    const pane = attachment.pane;
    if (pane.kind == .agent or pane.exit != null) {
        request.application.metrics.stale_client_messages += 1;
        return;
    }

    try forwardInput(request.application, pane, input.bytes);
    notePaneInput(request.application, request.session, input.pane_id);
}

fn notePaneInput(application: *Application, session: *Session, pane_id: core.PaneId) void {
    application.input_sequence +%= 1;
    if (application.input_sequence == 0) {
        for (&application.clients.items) |*slot| {
            const client = slot.* orelse continue;
            client.last_input_sequence = 0;
        }
        application.input_sequence = 1;
    }

    session.last_input_pane = pane_id;
    session.last_input_sequence = application.input_sequence;
}

/// Example: `try panes.routePaneResize(request, wire);`.
pub fn routePaneResize(request: *RequestContext, wire: core.PaneResize) !void {
    const result = try paneResize(request, .{
        .pane_id = wire.pane_id,
        .size = wire.size,
    });

    switch (result) {
        .handled => {},
        .pane_not_attached => request.application.metrics.stale_client_messages += 1,
        .geometry_rejected => request.application.metrics.geometry_rejections += 1,
    }
}

/// Example: `try panes.routeFrameAck(request, ack);`.
pub fn routeFrameAck(request: *RequestContext, ack: core.FrameAck) !void {
    const result = try frameAck(request, .{
        .pane_id = ack.pane_id,
        .frame_id = ack.frame_id,
        .received_at_ns = core.now(request.application.io),
    });

    switch (result) {
        .acknowledged => |elapsed| {
            if (comptime core.enabled) {
                request.application.metrics.ack.observe(elapsed);
            }
        },
        .stale => request.application.metrics.stale_client_messages += 1,
    }
}

/// Example: `try panes.routeRequestSnapshot(request, wire);`.
pub fn routeRequestSnapshot(request: *RequestContext, wire: core.RequestSnapshot) !void {
    _ = wire.known_frame_id;
    const result = try requestSnapshot(request, .{ .pane_id = wire.pane_id });

    if (result == .pane_not_attached) {
        request.application.metrics.stale_client_messages += 1;
    }
}

/// Example: `try panes.routeDetachPane(request, wire);`.
pub fn routeDetachPane(request: *RequestContext, wire: core.DetachPane) !void {
    const result = try detachPane(request, .{ .pane_id = wire.pane_id });

    if (result == .not_attached) {
        request.application.metrics.stale_client_messages += 1;
    }
}

/// Example: `try panes.routeCreatePane(request, wire);`.
pub fn routeCreatePane(request: *RequestContext, wire: core.CreatePaneView) !void {
    const launched = createPane(request, .{
        .location = wire.location,
        .size = wire.size,
        .launch = wire.launch,
    }) catch |err| {
        const failure: CreatePaneFailure = switch (err) {
            error.TabNotFound => .{ .code = .pane_not_found, .message = "tab not found" },
            error.GeometryUnavailable => .{ .code = .resource_limit, .message = "workspace geometry is leased by another client" },
            error.InvalidLaunchCwd => .{ .code = .invalid_request, .message = "cwd source pane is unavailable" },
            error.PaneLimitReached => .{ .code = .resource_limit, .message = "pane limit reached" },
            error.UnsupportedEnvironment => .{ .code = .invalid_request, .message = "custom pane environment is not supported" },
            error.PaneSpawnFailed => .{ .code = .spawn_failed, .message = "could not start pane process" },
            else => return err,
        };

        try createPaneQueueFailure(request, wire.request_id, failure);
        return;
    };

    try request.session.delivery.responses.push(.{ .pane_opened = .{
        .request_id = wire.request_id,
        .pane_id = launched.key.id,
        .location = launched.location,
        .created = true,
    } });
}

/// Example: `try panes.routeClosePane(request, wire);`.
pub fn routeClosePane(request: *RequestContext, wire: core.ClosePane) !void {
    const attachment = request.session.attachments.find(wire.pane_id) orelse {
        try request.session.delivery.responses.push(.{ .request_failed = .{
            .request_id = wire.request_id,
            .code = .pane_not_found,
            .message = "pane not attached",
        } });
        return;
    };

    _ = attachment.pane.requestClose();
}

/// Example: `try panes.routeSetPaneViewport(request, viewport);`.
pub fn routeSetPaneViewport(request: *RequestContext, viewport: core.SetPaneViewport) !void {
    const result = try setPaneViewport(request, .{
        .pane_id = viewport.pane_id,
        .offset = viewport.offset,
    });

    if (result == .pane_not_attached) {
        request.application.metrics.stale_client_messages += 1;
    }
}

/// Example: `try panes.routeReadPane(request, read);`.
pub fn routeReadPane(request: *RequestContext, read: core.ReadPane) !void {
    try request.session.delivery.responses.push(.{ .pane_text = .{
        .request_id = read.request_id,
        .pane = .{ .id = read.pane_id, .generation = read.pane_generation },
        .rows = read.rows,
        .source = read.source,
    } });
}

/// Example: `try panes.routeSendPaneText(request, wire);`.
pub fn routeSendPaneText(request: *RequestContext, wire: core.SendPaneText) !void {
    const result = try sendPaneText(request, .{
        .pane = .{ .id = wire.pane_id, .generation = wire.pane_generation },
        .mode = wire.mode,
        .text = wire.text,
    });

    switch (result) {
        .handled => try request.session.delivery.responses.push(.{ .request_completed = .{
            .request_id = wire.request_id,
        } }),
        .pane_not_found => try receiveSendPaneTextFail(request, .{
            .request_id = wire.request_id,
            .code = .pane_not_found,
            .message = "pane not found",
        }),
        .pane_exited => try receiveSendPaneTextFail(request, .{
            .request_id = wire.request_id,
            .code = .pane_exited,
            .message = "pane already exited",
        }),
        .not_terminal => try receiveSendPaneTextFail(request, .{
            .request_id = wire.request_id,
            .code = .invalid_request,
            .message = "agent panes require structured agent commands",
        }),
        .agent_blocked => try receiveSendPaneTextFail(request, .{
            .request_id = wire.request_id,
            .code = .agent_blocked,
            .message = "agent is waiting for a decision",
        }),
    }
}

/// Example: `try panes.routeSearchPane(request, search);`.
pub fn routeSearchPane(request: *RequestContext, search: core.SearchPane) !void {
    try pane_search.start(request.application, request.session, search);
}

/// Example: `try panes.routeCopySelection(request, selection);`.
pub fn routeCopySelection(request: *RequestContext, selection: core.CopySelection) !void {
    receiveCopySelection(request, selection);
}

fn findOpenPane(request: *RequestContext, pane_id: core.PaneId) ?*PaneType {
    const pane = request.application.model.panes.findRunning(pane_id) orelse return null;
    if (pane.close_requested or pane.exit != null) {
        return null;
    }

    return pane;
}

fn openPane(request: *RequestContext, command: OpenPane) anyerror!OpenPaneResult {
    var created = false;
    const active = switch (command.target) {
        .pane => |pane_id| findOpenPane(request, pane_id) orelse return error.PaneNotFound,
        .workspace => |workspace_id| workspace: {
            const workspace_location: core.WorkspaceLocation = .{ .workspace = workspace_id };
            const tab_id = request.workspaces.reader().defaultTab(workspace_location) orelse return error.WorkspaceNotFound;
            const location: core.TabLocation = .{
                .workspace = workspace_location,
                .tab_id = tab_id,
            };
            break :workspace request.application.model.panes.firstAt(location) orelse return error.WorkspaceHasNoPane;
        },
        .default => try openPaneOpenDefault(request, command, &created),
    };

    if (request.application.holdsGeometry(request.session.key, active.location.workspace)) {
        const resize_result = if (active.ingest_pending)
            active.requestResize(command.size)
        else
            active.resize(command.size);
        resize_result catch return error.PaneResizeFailed;
        try events.panes.Projection.scheduleObservation(request.application, active);
        try events.panes.Projection.scheduleMedia(request.application, active);
    }

    const attachment = try request.session.attachments.attach(request.application.gpa, active);
    _ = try attachment.resizeIfNeeded();
    return .{ .pane = .{ .key = active.key(), .location = active.location, .kind = active.kind }, .created = created };
}

fn openPaneOpenDefault(request: *RequestContext, command: OpenPane, created: *bool) !*PaneType {
    const launch = command.launch orelse return error.InvalidOpenRequest;
    const launch_cwd = launch_cwd_module.resolveLaunchCwd(&request.session.attachments, launch, .any) catch return error.InvalidLaunchCwd;
    var proposal: ?Proposal = null;
    defer if (proposal) |*candidate| {
        candidate.rollback();
    };

    const location = request.workspaces.reader().locationByPath(launch_cwd) orelse location: {
        proposal = request.workspaces.propose(.{ .path = launch_cwd }) catch return error.WorkspaceCreateFailed;
        break :location proposal.?.location();
    };

    if (request.application.model.panes.firstAt(location)) |existing| {
        return existing;
    }

    var provisional_lease = false;
    var committed = false;
    defer if (!committed and provisional_lease and proposal != null) {
        request.application.releaseGeometryFor(request.session.key, location.workspace);
    };

    if (!request.application.holdsGeometry(request.session.key, location.workspace)) {
        return error.GeometryUnavailable;
    }
    provisional_lease = true;

    const workspace_path = if (proposal) |*candidate|
        candidate.path()
    else
        request.workspaces.reader().workspacePath(location.workspace).?;
    const launched = request.application.launchPane(.{
        .location = location,
        .size = command.size,
        .launch = launch,
        .launch_cwd = launch_cwd,
        .workspace_path = workspace_path,
    }) catch |err| return open_pane_commands.mapLaunchError(err);

    if (proposal) |*candidate| {
        _ = candidate.commit();
        request.application.notifyWorkspaceChanged(request.session.key, location.workspace);
    }

    committed = true;
    created.* = true;
    request.application.notifyWorkspaceChanged(request.session.key, launched.location.workspace);
    return launched;
}

fn openPaneQueueFailure(request: *RequestContext, request_id: core.RequestId, failure: OpenPaneFailure) !void {
    try request.session.delivery.responses.push(.{ .request_failed = .{
        .request_id = request_id,
        .code = failure.code,
        .message = failure.message,
    } });
}

fn createPane(request: *RequestContext, command: CreatePane) anyerror!PaneLaunchedType {
    const application = request.application;

    if (!request.workspaces.reader().contains(command.location)) {
        return error.TabNotFound;
    }

    if (application.model.panes.countAt(command.location) == 0) {
        return error.TabNotFound;
    }

    if (!application.holdsGeometry(request.session.key, command.location.workspace)) {
        return error.GeometryUnavailable;
    }

    const launch_cwd = launch_cwd_module.resolveLaunchCwd(&request.session.attachments, command.launch, .{ .tab = command.location }) catch return error.InvalidLaunchCwd;
    const workspace_path = request.workspaces.reader().workspacePath(command.location.workspace) orelse return error.TabNotFound;
    const launched = application.launchPane(.{
        .location = command.location,
        .size = command.size,
        .launch = command.launch,
        .launch_cwd = launch_cwd,
        .workspace_path = workspace_path,
    }) catch |err| return create_pane.mapLaunchError(err);

    request.application.notifyWorkspaceChanged(request.session.key, launched.location.workspace);
    _ = try request.session.attachments.attach(application.gpa, launched);
    return .{ .key = launched.key(), .location = launched.location, .kind = launched.kind };
}

fn createPaneQueueFailure(request: *RequestContext, request_id: core.RequestId, failure: CreatePaneFailure) !void {
    try request.session.delivery.responses.push(.{ .request_failed = .{
        .request_id = request_id,
        .code = failure.code,
        .message = failure.message,
    } });
}

fn detachPane(request: *RequestContext, command: DetachPane) anyerror!detach_pane.DetachPaneResult {
    const detached = (request.session.attachments.detach(command.pane_id)) orelse return .not_attached;
    std.debug.assert(detached.pane_id == command.pane_id);

    if (detached.last_attachment) {
        const left_workspace = (request.session.attachments.leaveWorkspace(detached.workspace));

        if (!left_workspace) {
            return error.AttachmentStateConflict;
        }

        request.application.releaseGeometryFor(request.session.key, detached.workspace);
    }

    return .detached;
}

fn paneResize(request: *RequestContext, command: PaneResize) anyerror!pane_resize.PaneResizeResult {
    const session = request.session;

    const attachment = session.attachments.find(command.pane_id) orelse return .pane_not_attached;
    const pane = attachment.pane;

    if (!(request.application.holdsGeometry(request.session.key, pane.location.workspace))) {
        return .geometry_rejected;
    }

    try pane.requestResize(command.size);

    if (pane.ingest_pending) {
        return .handled;
    }

    pane.applyPendingResize() catch {
        _ = pane.requestClose();
        return .handled;
    };
    try events.panes.Projection.scheduleObservation(request.application, pane);
    try events.panes.Projection.scheduleMedia(request.application, pane);

    _ = attachment.resizeIfNeeded() catch {
        paneResizeDetachFailedProjection(request, command.pane_id);
        return .handled;
    };

    try events.panes.Io.scheduleResponse(request.application, pane);
    return .handled;
}

fn paneResizeDetachFailedProjection(request: *RequestContext, pane_id: core.PaneId) void {
    const session = request.session;

    const detached = session.attachments.detach(pane_id) orelse return;

    if (!detached.last_attachment) {
        return;
    }

    const left_workspace = session.attachments.leaveWorkspace(detached.workspace);
    std.debug.assert(left_workspace);

    if (left_workspace) {
        request.application.releaseGeometryFor(request.session.key, detached.workspace);
    }
}

fn frameAck(request: *RequestContext, command: AcknowledgeFrame) anyerror!frame_ack.FrameAckResult {
    const elapsed = request.session.attachments.acknowledgeFrame(.{
        .pane_id = command.pane_id,
        .frame_id = command.frame_id,
    }, command.received_at_ns) orelse return .stale;

    return .{ .acknowledged = elapsed };
}

fn requestSnapshot(request: *RequestContext, command: RequestCellSnapshot) anyerror!request_snapshot.RequestCellSnapshotResult {
    if (!request.session.attachments.requestCellSnapshot(command.pane_id)) {
        return .pane_not_attached;
    }

    return .requested;
}

fn setPaneViewport(request: *RequestContext, command: SetPaneViewport) anyerror!pane_viewport.SetPaneViewportResult {
    const update = try request.session.attachments.setPaneViewport(.{
        .pane_id = command.pane_id,
        .offset = command.offset,
    }) orelse return .pane_not_attached;

    return switch (update) {
        .changed => .changed,
        .unchanged => .unchanged,
    };
}

fn sendPaneText(request: *RequestContext, command: SendPaneText) anyerror!send_pane_text.SendPaneTextResult {
    const application = request.application;

    const pane = application.model.panes.resolveControl(command.pane) orelse return .pane_not_found;

    if (pane.kind == .agent) {
        return .not_terminal;
    }

    if (pane.exit != null) {
        return .pane_exited;
    }

    var storage: [core.max_pane_text_input_bytes + send_pane_text.prompt_overhead]u8 = undefined;
    const bytes = switch (command.mode) {
        .raw => command.text,
        .prompt => prompt: {
            if (application.model.agents.projectedStatus(command.pane) == .blocked) {
                return .agent_blocked;
            }

            break :prompt send_pane_text.promptBytes(&storage, command.text, pane.terminal.modes.get(.bracketed_paste));
        },
    };

    try forwardInput(request.application, pane, bytes);
    if (command.mode == .prompt or std.mem.indexOfScalar(u8, bytes, '\r') != null) {
        pane.noteInjectedSubmission();
    }

    return .handled;
}

fn receiveSendPaneTextFail(request: *RequestContext, failure: PendingFailureType) !void {
    try request.session.delivery.responses.push(.{ .request_failed = failure });
}

fn copySelection(request: *RequestContext, command: CopySelection, scratch: []u8) copy_selection.CopySelectionResult {
    const result = request.session.attachments.copySelection(command.pane_id, .{
        .range = .{
            .start_x = command.start_x,
            .start_y = command.start_y,
            .end_x = command.end_x,
            .end_y = command.end_y,
            .linewise = command.linewise,
        },
        .scratch = scratch,
    }) orelse return .pane_not_attached;

    return switch (result) {
        .copied => |bytes| .{ .copied = bytes },
        .unavailable => .unavailable,
        .too_large => .too_large,
    };
}

fn receiveCopySelection(request: *RequestContext, wire: core.CopySelection) void {
    var scratch: [selection_policy.scratch_bytes]u8 = undefined;

    const result = copySelection(request, .{
        .pane_id = wire.pane_id,
        .start_x = wire.start_x,
        .start_y = wire.start_y,
        .end_x = wire.end_x,
        .end_y = wire.end_y,
        .linewise = wire.linewise,
    }, &scratch);

    switch (result) {
        .copied => |bytes| {
            const accepted = request.session.delivery.setClipboard(wire.pane_id, bytes);
            std.debug.assert(accepted);
        },
        .pane_not_attached => request.application.metrics.stale_client_messages += 1,
        .unavailable, .too_large => {},
    }
}

fn forwardInput(application: *Application, pane: *PaneType, bytes: []const u8) !void {
    core.mark(application.io, .input_forward);
    if (comptime core.enabled) {
        application.metrics.input_events += 1;
        application.metrics.input_bytes += bytes.len;
    }

    if (if (application.agent_description_options != null) &application.model.agents else null) |tracker| {
        _ = tracker.observeInput(pane.key(), bytes);
    }

    core.mark(application.io, .foreground_start);
    const foreground = pane.session.shellForeground() orelse false;
    core.mark(application.io, .foreground_done);
    pane.queueHistoryInput(.{
        .bytes = bytes,
        .shell_foreground = foreground,
        .clock = pane_mod.historyClock(application.io),
    });
    core.mark(application.io, .input_observed);
    try events.panes.Projection.scheduleObservation(application, pane);

    if (pane.queuePtyInput(bytes) and bytes.len != 0) {
        pane.cell_input_ns = core.monotonic(application.io);
    }

    try events.panes.Io.scheduleInput(application, pane);
}
