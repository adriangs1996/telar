/// Owns the live model and application state used by requests and actors.
const Application = @This();
const source_namespace = @import("root.zig");
const std = @import("std");
const history = @import("../../history/root.zig");
const pty = @import("../../pty/root.zig");
const core = @import("telar-core");
const proxy_resource = @import("../resources/proxy.zig");
const plugins = @import("../../plugins/root.zig");
const engine = @import("../../engine/root.zig");
const shutdown_module = @import("../lifecycle/root.zig").shutdown_authority;
const GeometryLease = @import("GeometryLease.zig");
const observability = @import("../observability/root.zig");
const session_checkpoint = @import("session_checkpoint.zig");
const Initialization = @import("Initialization.zig");
const workspace_mod = @import("../../workspace/root.zig");
const pane_launcher = @import("pane_launcher.zig");
const agent_mod = @import("../../agent/root.zig");
const git_status = @import("git_status.zig");
const session_name = @import("session_name.zig");
const WorkspaceChange = @import("WorkspaceChange.zig");
const attachment_mod = @import("../attachment/root.zig");
io: source_namespace.Io,
gpa: std.mem.Allocator,
heap: *source_namespace.diagnostics.Heap,
select: *source_namespace.Io.Select(source_namespace.RuntimeEvent),
history_service: *history.Service,
child_environment: *const pty.ChildEnvironment,
inherited_environment: std.process.Environ,
socket_path: []const u8,
executable_path: [std.fs.max_path_bytes]u8 = undefined,
executable_path_len: usize,
agent_manifests: *const core.agent_manifest.Table,
proxy_runtime: *proxy_resource.Runtime,
plugin_service: *plugins.Service,
agent_description_options: ?source_namespace.AgentDescriptionOptions,
agent_description_state: source_namespace.agent_description_coordinator.State = .{},
/// The headless engine, when `runtime.engine` is configured.
engine_service: ?*engine.Service,
launch_fault: ?*source_namespace.LaunchTestFault,
clients: *source_namespace.ClientStore,
client_admission: source_namespace.ClientAdmissionState = .{},
shutdown: shutdown_module.State = .{},
geometry_leases: [source_namespace.max_workspaces]?GeometryLease = @splat(null),
model: source_namespace.RuntimeModel,
system_metrics: observability.system_metrics.Sampler = .{},
system_metrics_pending: bool = false,
metrics: source_namespace.RuntimeMetrics,
session: session_checkpoint.State = .{},
session_name_probe_in_flight: bool = false,
input_sequence: u64 = 0,

/// Composes application state from stable, runtime-owned capabilities.
///
/// ```zig
/// const application = try Application.init(initialization);
/// ```
pub fn init(initialization: Initialization) !Application {
    var executable_path: [std.fs.max_path_bytes]u8 = undefined;
    const executable_path_len = try std.process.executablePath(initialization.io, &executable_path);

    return .{
        .io = initialization.io,
        .gpa = initialization.gpa,
        .heap = initialization.heap,
        .select = initialization.select,
        .history_service = initialization.history_service,
        .child_environment = initialization.child_environment,
        .inherited_environment = initialization.inherited_environment,
        .socket_path = initialization.socket_path,
        .executable_path = executable_path,
        .executable_path_len = executable_path_len,
        .agent_manifests = initialization.agent_manifests,
        .session = .{ .path = initialization.session_path, .resume_agents = initialization.resume_agents },
        .proxy_runtime = initialization.proxy_runtime,
        .plugin_service = initialization.plugin_service,
        .agent_description_options = initialization.agent_description_options,
        .engine_service = initialization.engine_service,
        .launch_fault = initialization.launch_fault,
        .clients = initialization.clients,
        .model = .{
            .panes = .{
                .graphics_limits = initialization.graphics,
                .graphics_budget = .init(initialization.graphics.global_bytes),
            },
            .client_layouts = try .init(initialization.gpa),
        },
        .metrics = .{ .started_ns = source_namespace.diagnostics.now(initialization.io) },
    };
}

/// Performs the application-owned part of one ordered runtime shutdown step.
///
/// ```zig
/// application.shutdownStep(.stop_client_connections);
/// ```
pub fn shutdownStep(application: *Application, step: source_namespace.ShutdownStep) void {
    switch (step) {
        .stop_client_connections => {
            source_namespace.SessionCheckpoint.writeNow(application);
            for (&application.clients.items) |*slot| {
                if (slot.*) |session| {
                    session.connection.shutdown(application.io);
                }
            }
        },
        .stop_pending_admission => {
            if (application.client_admission.pendingConnection()) |pending| {
                pending.shutdown(application.io);
            }
        },
        .stop_panes => application.model.panes.shutdown(),
        .destroy_pending_admission => {
            if (application.client_admission.pendingConnection()) |pending| {
                pending.deinit(application.io);
            }
        },
        .release_client_actor_claims => {
            for (&application.clients.items) |*slot| {
                if (slot.*) |session| {
                    session.read_pending = false;
                    session.send_pending = false;
                }
            }
        },
        .destroy_client_sessions => application.clients.deinit(application.io, application.gpa),
        .destroy_panes => application.model.panes.deinit(),
        .destroy_workspaces => {
            application.model.client_layouts.deinit();
            source_namespace.deinitWorkspaces(application);
        },
    }
}

/// Reaps lifecycle work that became collectible after an actor completed.
///
/// ```zig
/// application.collect();
/// ```
pub fn collect(application: *Application) void {
    application.collectFinished();
}

/// Revokes the proxy credential associated with a pane, when enabled.
///
/// ```zig
/// application.revokePaneCredential(pane);
/// ```
pub fn revokePaneCredential(application: *Application, pane: *source_namespace.Pane) void {
    if (application.proxy_runtime.capability()) |proxy| {
        proxy.revokePane(pane.key());
    }
}

/// Opens the repository used by one request-scoped workspace operation.
///
/// ```zig
/// var workspaces = application.workspaceRepository();
/// ```
pub fn workspaceRepository(application: *Application) source_namespace.WorkspaceRepository {
    return source_namespace.WorkspaceRepository.init(&application.model.workspaces, application.gpa);
}

/// Returns a read-only view of the current workspace projection.
///
/// ```zig
/// const workspaces = application.workspaceReader();
/// ```
pub fn workspaceReader(application: *const Application) workspace_mod.Reader {
    return workspace_mod.Reader.init(&application.model.workspaces);
}

/// Starts a pane and returns only after the runtime can observe both its
/// output and exit. Client attachment and response delivery happen later.
/// ```zig
/// const pane = try application.launchPane(request);
/// ```
pub fn launchPane(application: *Application, request: pane_launcher.LaunchRequest) !*source_namespace.Pane {
    var launcher: source_namespace.PaneLauncher(source_namespace.RuntimeEvent) = .{
        .io = application.io,
        .gpa = application.gpa,
        .select = application.select,
        .history_service = application.history_service,
        .inherited_environment = application.inherited_environment,
        .socket_path = application.socket_path,
        .executable_path = application.executable_path[0..application.executable_path_len],
        .manifests = application.agent_manifests,
        .proxy = application.proxy_runtime.capability(),
        .panes = &application.model.panes,
        .launch_fault = application.launch_fault,
        .terminal_colors = application.workspaceTerminalColors(request.location.workspace),
    };
    const fresh = try launcher.launch(request);
    application.model.agents.touch();
    application.noteSessionChange();
    return fresh;
}

/// Queues bytes for a restored pane's child and starts the input write.
/// The bytes are a runtime-built resume command, never client input.
///
/// ```zig
/// try application.queueRestoredInput(pane, "claude --resume <id>\r");
/// ```
pub fn queueRestoredInput(application: *Application, pane: *source_namespace.Pane, bytes: []const u8) !void {
    if (std.mem.indexOfScalar(u8, bytes, '\r') != null) {
        pane.noteInjectedSubmission();
    }

    _ = pane.queuePtyInput(bytes);
    try source_namespace.RuntimeEvents.schedulePaneInput(application, pane);
}

/// Hands a checkpointed title to the agent that will resume in a restored
/// pane and records it for the pane's new history session, so the sidebar
/// and the history palette show the resumed session under its old name.
///
/// ```zig
/// application.restoreAgentTitle(pane, title);
/// ```
pub fn restoreAgentTitle(application: *Application, pane: *const source_namespace.Pane, title: agent_mod.SessionTitle) void {
    if (!application.model.agents.restoreTitle(pane.key(), title)) {
        return;
    }

    _ = application.history_service.setSessionTitle(application.io, .{
        .id = pane.history_session_id,
        .title = title.slice(),
        .source = title.source,
        .state = .ready,
    });
}

/// Marks the restorable session shape as changed so the next maintenance
/// tick persists it.
///
/// ```zig
/// application.noteSessionChange();
/// ```
pub fn noteSessionChange(application: *Application) void {
    source_namespace.SessionCheckpoint.noteChange(application);
}

/// Rebuilds the model from the checkpoint file. Runs once at startup,
/// before clients are accepted.
///
/// ```zig
/// application.restoreSession();
/// ```
pub fn restoreSession(application: *Application) void {
    source_namespace.SessionCheckpoint.restore(application);
}

/// Starts a checkpoint write when one is due.
///
/// ```zig
/// try application.flushSessionCheckpoint();
/// ```
pub fn flushSessionCheckpoint(application: *Application) !void {
    try source_namespace.SessionCheckpoint.flushIfDue(application);
}

/// Starts one git probe for the stalest due workspace.
///
/// ```zig
/// application.tickGitStatus();
/// ```
pub fn tickGitStatus(application: *Application) void {
    source_namespace.GitObserver.tick(application);
}

/// Applies one git probe result.
///
/// ```zig
/// application.gitStatusCompleted(completion);
/// ```
pub fn gitStatusCompleted(application: *Application, completion: git_status.Completion) void {
    source_namespace.GitObserver.handleCompletion(application, completion);
}

/// Starts one session-file probe for the stalest due agent.
///
/// ```zig
/// application.tickSessionNames();
/// ```
pub fn tickSessionNames(application: *Application) void {
    source_namespace.SessionNameObserver.tick(application);
}

/// Applies one session-file probe result.
///
/// ```zig
/// application.sessionNameCompleted(completion);
/// ```
pub fn sessionNameCompleted(application: *Application, completion: session_name.Completion) void {
    source_namespace.SessionNameObserver.handleCompletion(application, completion);
}

/// Completes the in-flight checkpoint write.
///
/// ```zig
/// application.sessionCheckpointWritten(result);
/// ```
pub fn sessionCheckpointWritten(application: *Application, result: anyerror!void) void {
    source_namespace.SessionCheckpoint.handleWritten(application, result);
}

/// Reaps panes whose child exited and which no actor still borrows, then
/// closes tabs that ran out of panes. Spans three stores, which is why it
/// lives on the application rather than on any one of them.
fn collectFinished(application: *Application) void {
    const store = &application.model.panes;
    var workspaces = application.workspaceRepository();

    if (store.exited_count == 0) {
        return;
    }

    for (&store.items) |*slot| {
        const pane = slot.* orelse continue;

        if (!pane.readyToDestroy()) {
            continue;
        }

        for (&application.clients.items) |*client_slot| {
            const client = client_slot.* orelse continue;
            if (client.attachments.find(pane.id) != null) {
                break;
            }
        } else {
            const location = pane.location;
            store.index.remove(source_namespace.schema.id.raw(pane.id));
            store.exited_count -= 1;
            slot.* = null;
            store.count -= 1;

            if (!application.model.agents.remove(pane.key())) {
                application.model.agents.touch();
            }

            application.revokePaneCredential(pane);
            pane.destroy();
            application.noteSessionChange();

            if (!store.hasAt(location) and workspaces.reader().contains(location)) {
                const removed = workspace_mod.removeTab(&workspaces, location).?;
                application.publishLifecycleTabRemoved(removed);
            }

            application.completeEmptyWorkspaceDepartures(location.workspace);
        }
    }
}

/// Starts idempotent client teardown and removes it after actor claims end.
///
/// ```zig
/// application.dropClient(client);
/// ```
pub fn dropClient(application: *Application, key: source_namespace.ClientKey) void {
    const session = application.clients.resolve(key) orelse return;
    if (!session.closing) {
        application.failPaneFocusesFor(key);
        session.closing = true;
        session.connection.shutdown(application.io);
        session.attachments.deinit();
        session.delivery.close();
        application.releaseGeometry(key);
        application.collect();
        // Deliver the resync notices now rather than on the next tick.
        // Re-entry from a pump failure is bounded: every dropClient marks
        // its session closing, and closing sessions are never pumped.
        application.pumpAll();
    }
    application.finalizeClient(key);
}

fn failPaneFocusesFor(application: *Application, key: source_namespace.ClientKey) void {
    for (&application.clients.items) |*slot| {
        const requester = slot.* orelse continue;
        const pending = requester.pending_pane_focus orelse continue;

        if (!std.meta.eql(pending.target, key)) {
            continue;
        }

        requester.releaseFocus();
        requester.delivery.responses.push(.{ .request_failed = .{
            .request_id = pending.request_id,
            .code = .invalid_request,
            .message = "focus client disconnected",
        } }) catch {
            application.dropClient(requester.key);
            continue;
        };
        requester.delivery.close_after_reply = true;
    }
}

/// Removes a closing client once no read or write actor still owns it.
///
/// ```zig
/// application.finalizeClient(client);
/// ```
pub fn finalizeClient(application: *Application, key: source_namespace.ClientKey) void {
    const session = application.clients.resolve(key) orelse return;

    if (!session.closing or session.read_pending or session.send_pending) {
        return;
    }

    _ = application.clients.remove(.{ .io = application.io, .gpa = application.gpa }, key);
}

/// Acquires or verifies the workspace geometry lease for one client.
///
/// ```zig
/// if (!application.holdsGeometry(client, workspace)) return error.GeometryUnavailable;
/// ```
pub fn holdsGeometry(application: *Application, key: source_namespace.ClientKey, workspace: source_namespace.schema.WorkspaceLocation) bool {
    for (&application.geometry_leases) |*slot| {
        const lease = slot.* orelse continue;

        if (!std.meta.eql(lease.workspace, workspace)) {
            continue;
        }

        return std.meta.eql(lease.owner, key);
    }

    for (&application.geometry_leases) |*slot| {
        if (slot.* != null) {
            continue;
        }

        slot.* = .{ .workspace = workspace, .owner = key };
        application.applyWorkspaceTerminalColors(workspace, key);
        return true;
    }

    return false;
}

/// Queries authority without acquiring an unowned workspace.
/// Example: `const owner = application.geometryOwner(workspace) orelse return;`.
pub fn geometryOwner(application: *const Application, workspace: source_namespace.schema.WorkspaceLocation) ?source_namespace.ClientKey {
    for (application.geometry_leases) |slot| {
        const lease = slot orelse continue;
        if (std.meta.eql(lease.workspace, workspace)) {
            return lease.owner;
        }
    }

    return null;
}

pub fn workspaceTerminalColors(application: *Application, workspace: source_namespace.schema.WorkspaceLocation) source_namespace.schema.TerminalColors {
    const owner = application.geometryOwner(workspace) orelse return .{};
    const session = application.clients.resolve(owner) orelse return .{};
    return session.terminal_colors;
}

/// Updates only workspaces already controlled by this exact generation.
/// Example: `application.refreshTerminalColors(session.key);`.
pub fn refreshTerminalColors(application: *Application, key: source_namespace.ClientKey) void {
    for (application.geometry_leases) |slot| {
        const lease = slot orelse continue;
        if (std.meta.eql(lease.owner, key)) {
            application.applyWorkspaceTerminalColors(lease.workspace, key);
        }
    }
}

fn applyWorkspaceTerminalColors(application: *Application, workspace: source_namespace.schema.WorkspaceLocation, key: source_namespace.ClientKey) void {
    const session = application.clients.resolve(key) orelse return;
    for (application.model.panes.items) |slot| {
        const pane = slot orelse continue;
        if (std.meta.eql(pane.location.workspace, workspace)) {
            pane.setTerminalColors(session.terminal_colors);
        }
    }
}

fn releaseGeometry(application: *Application, key: source_namespace.ClientKey) void {
    for (&application.geometry_leases) |*slot| {
        const lease = slot.* orelse continue;

        if (!std.meta.eql(lease.owner, key)) {
            continue;
        }

        slot.* = null;
        // The lease is free but the runtime does not know any surviving
        // client's size. Resync the observers so one re-offers its
        // geometry and takes the lease over; without this the pane keeps
        // the departed client's size until an unrelated resize.
        application.notifyWorkspaceChanged(key, lease.workspace);
    }
}

/// Releases a client's lease for one workspace and requests observer resync.
///
/// ```zig
/// application.releaseGeometryFor(client, workspace);
/// ```
pub fn releaseGeometryFor(application: *Application, key: source_namespace.ClientKey, workspace: source_namespace.schema.WorkspaceLocation) void {
    for (&application.geometry_leases) |*slot| {
        const lease = slot.* orelse continue;
        if (std.meta.eql(lease.owner, key) and std.meta.eql(lease.workspace, workspace)) {
            slot.* = null;
            application.notifyWorkspaceChanged(key, workspace);
        }
    }
}

/// Queues resynchronization for observers other than the mutation origin.
///
/// ```zig
/// application.notifyWorkspaceChanged(origin, workspace);
/// ```
pub fn notifyWorkspaceChanged(application: *Application, origin: source_namespace.ClientKey, workspace: source_namespace.schema.WorkspaceLocation) void {
    application.notifyWorkspaceChange(.{ .origin = origin, .workspace = workspace });
}

/// Queues resynchronization after a workspace disappears.
///
/// ```zig
/// application.notifyWorkspaceClosed(change);
/// ```
pub fn notifyWorkspaceClosed(application: *Application, change: WorkspaceChange) void {
    application.notifyWorkspaceChange(change);
}

fn notifyWorkspaceChange(application: *Application, change: WorkspaceChange) void {
    for (&application.clients.items) |*slot| {
        const session = slot.* orelse continue;

        if (std.meta.eql(session.key, change.origin) or !session.active()) {
            continue;
        }

        if (session.attachments.observes(change.workspace)) {
            session.delivery.responses.resync_workspace = change.workspace;
            session.delivery.responses.resync_previous_workspace = change.previous_workspace;
        }
    }
}

/// Detaches one pane and completes any resulting workspace departure.
///
/// ```zig
/// const detached = application.detachSessionPane(session, pane_id);
/// ```
pub fn detachSessionPane(application: *Application, session: *source_namespace.ClientSession, pane_id: source_namespace.schema.PaneId) ?attachment_mod.PaneDetached {
    const detached = session.attachments.detach(pane_id) orelse return null;
    application.completeSessionWorkspaceDeparture(session, detached);
    return detached;
}

fn completeSessionWorkspaceDeparture(application: *Application, session: *source_namespace.ClientSession, detached: attachment_mod.PaneDetached) void {
    if (!detached.last_attachment) {
        return;
    }

    const left_workspace = session.attachments.leaveWorkspace(detached.workspace);
    std.debug.assert(left_workspace);

    if (!left_workspace) {
        return;
    }

    application.releaseGeometryFor(session.key, detached.workspace);
}

/// Completes departures deferred by `pane_exited` only after every pane
/// that can still publish lifecycle changes for the workspace is reaped.
fn completeEmptyWorkspaceDepartures(application: *Application, workspace: source_namespace.schema.WorkspaceLocation) void {
    if (application.hasPendingExitedPane(workspace)) {
        return;
    }

    for (&application.clients.items) |*slot| {
        const session = slot.* orelse continue;

        if (session.attachments.len() != 0 or !session.attachments.observes(workspace)) {
            continue;
        }

        const left_workspace = session.attachments.leaveWorkspace(workspace);
        std.debug.assert(left_workspace);

        if (left_workspace) {
            application.releaseGeometryFor(session.key, workspace);
        }
    }
}

fn hasPendingExitedPane(application: *const Application, workspace: source_namespace.schema.WorkspaceLocation) bool {
    for (application.model.panes.items) |slot| {
        const pane = slot orelse continue;

        if (pane.exit != null and std.meta.eql(pane.location.workspace, workspace)) {
            return true;
        }
    }

    return false;
}

/// Delivers an automatic tab-removal fact to every client that still
/// observes its workspace. Queue saturation records snapshot recovery.
fn publishLifecycleTabRemoved(application: *Application, removed: workspace_mod.TabRemoved) void {
    for (&application.clients.items) |*client_slot| {
        const client = client_slot.* orelse continue;

        if (!client.active() or !client.attachments.observes(removed.location.workspace)) {
            continue;
        }

        client.delivery.responses.pushOrDrop(.{ .tab_closed = .{
            .request_id = .none,
            .location = removed.location,
            .workspace_closed = removed.workspace_removed,
            .previous_workspace = removed.previous_workspace,
        } });
    }
}

/// Publishes a notification to active UI sessions and returns the number queued.
///
/// ```zig
/// const recipients = application.publishNotification(notification);
/// ```
pub fn publishNotification(application: *Application, notification: source_namespace.schema.Notification) u8 {
    const pending = source_namespace.PendingNotification.init(notification);
    var delivered: u8 = 0;

    for (&application.clients.items) |*slot| {
        const recipient = slot.* orelse continue;

        if (!recipient.active() or recipient.role != .ui) {
            continue;
        }

        if (recipient.delivery.responses.pushNotification(pending)) {
            delivered += 1;
        }
    }

    return delivered;
}

/// Queues an agent sound for every active UI client.
///
/// ```zig
/// application.publishAgentSound(notification);
/// ```
pub fn publishAgentSound(application: *Application, notification: source_namespace.schema.AgentSoundNotification) void {
    for (&application.clients.items) |*slot| {
        const recipient = slot.* orelse continue;

        if (!recipient.active() or recipient.role != .ui) {
            continue;
        }

        _ = recipient.delivery.responses.pushAgentSound(notification);
    }
}

/// Advances delivery for every active client and settles observed pane damage.
///
/// ```zig
/// application.pumpAll();
/// ```
pub fn pumpAll(application: *Application) void {
    for (&application.clients.items) |*slot| {
        const session = slot.* orelse continue;
        const key = session.key;
        application.pump(session) catch application.dropClient(key);
    }
    for (application.model.panes.items) |slot| {
        const pane = slot orelse continue;
        application.settlePaneDamage(pane);
    }
}

fn settlePaneDamage(application: *Application, pane: *source_namespace.Pane) void {
    if (pane.render_pending) {
        return;
    }

    for (&application.clients.items) |*slot| {
        const session = slot.* orelse continue;
        const attachment = session.attachments.find(pane.id) orelse continue;

        if (attachment.observedCellRevision() != pane.cell_revision) {
            return;
        }
    }

    @memset(pane.damaged_rows, false);
    pane.dirty = false;
}

/// Reports whether every live client has consumed the shutdown delivery.
///
/// ```zig
/// if (application.shutdownDelivered()) return;
/// ```
pub fn shutdownDelivered(application: *const Application) bool {
    if (!application.shutdown.isRequested()) {
        return false;
    }

    for (&application.clients.items) |*slot| {
        const session = slot.* orelse continue;
        if (!session.closing and
            (session.delivery.stopping() or session.send_pending))
        {
            return false;
        }
    }

    return true;
}

/// Prepares and schedules at most one delivery for an active client.
///
/// ```zig
/// try application.pump(session);
/// ```
pub fn pump(application: *Application, session: *source_namespace.ClientSession) !void {
    if (!session.active() or session.send_pending) {
        return;
    }

    const pending = try session.delivery.prepare(.{
        .io = application.io,
        .attachments = &session.attachments,
        .sources = .{
            .panes = &application.model.panes,
            .workspaces = application.workspaceReader(),
            .agents = &application.model.agents,
            .manifests = application.agent_manifests,
            .system_metrics = &application.system_metrics,
            .proxy_active = application.proxy_runtime.active(),
            .proxy_scope = application.proxy_runtime.interceptionScope(),
            .proxy_system_trusted = application.proxy_runtime.systemTrusted(),
            .home = application.inherited_environment.getPosix("HOME"),
            .client_layouts = &application.model.client_layouts,
        },
        .metrics = &application.metrics,
    });
    errdefer if (pending) |prepared| {
        session.delivery.abort(prepared);
    };

    for (0..attachment_mod.AttachmentStore.capacity) |index| {
        const attachment = session.attachments.at(index) orelse continue;
        if (attachment.pane.media.hasPending()) {
            try source_namespace.RuntimeEvents.schedulePaneMedia(application, attachment.pane);
        }
    }

    const prepared = pending orelse return;
    try source_namespace.Operations.startSessionSend(application, session, prepared.payload);
    session.delivery.commit(.{
        .prepared = prepared,
        .attachments = &session.attachments,
        .metrics = &application.metrics,
    });
}

/// Routes a decoded client message through a request-scoped dispatcher.
///
/// ```zig
/// try application.dispatchClientMessage(session, message);
/// ```
pub fn dispatchClientMessage(application: *Application, session: *source_namespace.ClientSession, message: source_namespace.schema.ClientMessage) !void {
    return source_namespace.RequestDispatcher.dispatch(application, session, message);
}
