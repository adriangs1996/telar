//! Long-lived runtime for Telar's current schema.

const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");
const agent_mod = @import("../agent/root.zig");
const agent_process = @import("../process/root.zig");
const history = @import("../history/root.zig");
const attachment_mod = @import("attachment.zig");
const client_request_router = @import("client_request_router.zig");
const delivery_mod = @import("delivery.zig");
const entrypoint_common = @import("entrypoints/common.zig");
const close_tab_commands = @import("commands/close_tab.zig");
const close_tab_controller = @import("controllers/close_tab.zig");
const close_pane_commands = @import("commands/close_pane.zig");
const close_pane_controller = @import("controllers/close_pane.zig");
const copy_selection_commands = @import("commands/copy_selection.zig");
const copy_selection_controller = @import("controllers/copy_selection.zig");
const create_tab_commands = @import("commands/create_tab.zig");
const create_tab_controller = @import("controllers/create_tab.zig");
const create_pane_commands = @import("commands/create_pane.zig");
const create_pane_controller = @import("controllers/create_pane.zig");
const create_workspace_commands = @import("commands/create_workspace.zig");
const create_workspace_controller = @import("controllers/create_workspace.zig");
const detach_pane_commands = @import("commands/detach_pane.zig");
const detach_pane_controller = @import("controllers/detach_pane.zig");
const frame_ack_commands = @import("commands/frame_ack.zig");
const frame_ack_controller = @import("controllers/frame_ack.zig");
const graphics_configuration_commands = @import("commands/graphics_configuration.zig");
const graphics_configuration_controller = @import("controllers/graphics_configuration.zig");
const graphics_credit_commands = @import("commands/graphics_credit.zig");
const graphics_credit_controller = @import("controllers/graphics_credit.zig");
const history_query = @import("queries/history.zig");
const history_query_controller = @import("controllers/history_query.zig");
const move_tab_commands = @import("commands/move_tab.zig");
const move_tab_controller = @import("controllers/move_tab.zig");
const open_pane_commands = @import("commands/open_pane.zig");
const open_pane_controller = @import("controllers/open_pane.zig");
const pane_input_commands = @import("commands/pane_input.zig");
const pane_input_controller = @import("controllers/pane_input.zig");
const pane_input_pump = @import("pane_input_pump.zig");
const pane_response_pump = @import("pane_response_pump.zig");
const pane_resize_commands = @import("commands/pane_resize.zig");
const pane_resize_controller = @import("controllers/pane_resize.zig");
const pane_viewport_commands = @import("commands/pane_viewport.zig");
const pane_viewport_controller = @import("controllers/pane_viewport.zig");
const request_graphics_snapshot_commands = @import("commands/request_graphics_snapshot.zig");
const request_graphics_snapshot_controller = @import("controllers/request_graphics_snapshot.zig");
const request_snapshot_commands = @import("commands/request_snapshot.zig");
const request_snapshot_controller = @import("controllers/request_snapshot.zig");
const runtime_stop_commands = @import("commands/runtime_stop.zig");
const runtime_stop_controller = @import("controllers/runtime_stop.zig");
const runtime_state_controller = @import("controllers/runtime_state.zig");
const rename_workspace_commands = @import("commands/rename_workspace.zig");
const rename_workspace_controller = @import("controllers/rename_workspace.zig");
const show_notification_commands = @import("commands/show_notification.zig");
const show_notification_controller = @import("controllers/show_notification.zig");
const tab_snapshot_query = @import("queries/tab_snapshot.zig");
const tab_snapshot_controller = @import("controllers/tab_snapshot.zig");
const workspace_snapshot_query = @import("queries/workspace_snapshot.zig");
const workspace_snapshot_controller = @import("controllers/workspace_snapshot.zig");
const tab_commands = @import("commands/tab.zig");
const tab_controller = @import("controllers/tab.zig");
const pane_launcher_mod = @import("pane_launcher.zig");
const pane_output_pipeline = @import("pane_output_pipeline.zig");
const pane_mod = @import("../pane/root.zig");
const blit = pane_mod.blit;
const media_mod = @import("../media/root.zig");
const model_mod = @import("model/root.zig");
const pty = @import("../pty/root.zig");
const response_queue = @import("response_queue.zig");
const shutdown_mod = @import("shutdown.zig");
const proxy_mod = @import("../proxy/root.zig");
const runtime_encoder = @import("encoder.zig");
pub const system_metrics = @import("system_metrics.zig");
const system_metrics_mod = system_metrics;
const telemetry_mod = @import("telemetry.zig");
const transport = @import("../transport/root.zig");
const workspace_mod = @import("../workspace/root.zig");

const Io = std.Io;
const File = Io.File;
const schema = core.schema;
const diagnostics = core.diagnostics;

pub const GraphicsLimits = pane_mod.GraphicsLimits;
const Pane = pane_mod.Pane;
const PaneKey = pane_mod.PaneKey;
const PaneIngestStats = pane_mod.PaneIngestStats;
const PaneStore = pane_mod.PaneStore;
const PaneLauncher = pane_launcher_mod.PaneLauncher;
const max_panes = pane_mod.max_panes;
const WorkspaceRepository = workspace_mod.Repository;
const WorkspaceState = workspace_mod.State;
const max_workspaces = workspace_mod.max_workspaces;
const RuntimeModel = model_mod.RuntimeModel;
const AttachmentStore = attachment_mod.AttachmentStore;
const Delivery = delivery_mod.Delivery;
const enforceGraphicsQuotas = attachment_mod.enforceGraphicsQuotas;
const RuntimeMetrics = telemetry_mod.RuntimeMetrics;
const CopySelectionController = copy_selection_controller.Controller(*copy_selection_commands.CopySelectionHandler, *Delivery);
const FrameAckController = frame_ack_controller.Controller(*frame_ack_commands.FrameAckHandler);
const GraphicsConfigurationController = graphics_configuration_controller.Controller(*graphics_configuration_commands.ConfigureGraphicsHandler);
const GraphicsCreditController = graphics_credit_controller.Controller(*graphics_credit_commands.ReturnGraphicsCreditHandler);
const PaneInputController = pane_input_controller.Controller(*pane_input_commands.PaneInputHandler);
const PaneResizeController = pane_resize_controller.Controller(*pane_resize_commands.PaneResizeHandler);
const PaneViewportController = pane_viewport_controller.Controller(*pane_viewport_commands.SetPaneViewportHandler);
const RequestGraphicsSnapshotController = request_graphics_snapshot_controller.Controller(*request_graphics_snapshot_commands.RequestGraphicsSnapshotHandler);
const RequestSnapshotController = request_snapshot_controller.Controller(*request_snapshot_commands.RequestCellSnapshotHandler);
const RuntimeStateController = runtime_state_controller.Controller(*Delivery);
const formatRuntimeTelemetry = telemetry_mod.formatRuntimeTelemetry;
const max_clients = 8;
const PendingResponse = response_queue.PendingResponse;
const PendingNotification = response_queue.PendingNotification;
const ResponseQueue = response_queue.ResponseQueue;
const encodeResponse = runtime_encoder.encodeResponse;

fn agentSoundForTransition(previous: ?schema.AgentStatus, current: ?schema.AgentStatus) ?schema.AgentSound {
    if (previous != .working) return null;
    return switch (current orelse return null) {
        .ready => .ready,
        .blocked => .needs_input,
        .unknown, .working, .failed => null,
    };
}

pub const ServeOptions = struct {
    graphics: GraphicsLimits = .{},
    environment: std.process.Environ,
    /// SQLite database for durable history; the default keeps it in memory.
    history_path: [:0]const u8 = ":memory:",
    proxy: ?ProxyOptions = null,
    agent_descriptions: ?AgentDescriptionOptions = null,
    /// Test seam: stops the otherwise long-lived runtime without signals.
    stop: ?*Io.Queue(u8) = null,
    /// Test seam: holds a pane's ingest actor open. See `IngestTestGate`.
    ingest_gate: ?*IngestTestGate = null,
    /// Test seam: fails one pane launch at a selected post-spawn phase.
    launch_fault: ?*LaunchTestFault = null,
};

pub const AgentDescriptionOptions = struct {
    arguments: []const []const u8,
    timeout_ms: u32,
};

pub const ProxyOptions = struct {
    key_path: []const u8,
    certificate_path: []const u8,
    bundle_path: []const u8,
    passthrough_hosts: []const []const u8 = &.{},
};

pub const ClientKey = history.model.ClientKey;

const ClientMessageEvent = struct {
    client: ClientKey,
    result: anyerror![]u8,
};

const ClientSentEvent = struct {
    client: ClientKey,
    result: anyerror!void,
};

const PaneOutputEvent = pane_launcher_mod.PaneOutputEvent;

const PaneIngestEvent = struct {
    pane: PaneKey,
    result: anyerror!PaneIngestStats,
};

const PaneObservationEvent = struct {
    pane: PaneKey,
    stats: history.observer.Stats,
    process_probe: agent_process.Probe,
};

const PaneMediaEvent = struct {
    pane: PaneKey,
    stats: media_mod.Stats,
};

const PaneInputEvent = pane_input_pump.Completion;

const PaneExitEvent = pane_launcher_mod.PaneExitEvent;

const PaneResponseEvent = pane_response_pump.Completion;

const RuntimeEvent = union(enum) {
    accepted: anyerror!core.transport.SocketChannel,
    handshaken: anyerror!void,
    client_message: ClientMessageEvent,
    client_sent: ClientSentEvent,
    history_response: anyerror!history.Response,
    pane_input_written: PaneInputEvent,
    pane_response_written: PaneResponseEvent,
    pane_output: PaneOutputEvent,
    pane_ingested: PaneIngestEvent,
    pane_observed: PaneObservationEvent,
    pane_media: PaneMediaEvent,
    pane_exit: PaneExitEvent,
    telemetry_tick: anyerror!void,
    telemetry_written: anyerror!void,
    proxy_event: anyerror!proxy_mod.Observation,
    agent_tick: anyerror!void,
    agent_description: agent_mod.description.Result,
    metrics_tick: anyerror!void,
    stopped: anyerror!void,
};

const ClientRole = enum { undecided, ui, control };

const ClientSession = struct {
    key: ClientKey,
    connection: core.transport.SocketChannel,
    receive_buffer: []u8,
    attachments: AttachmentStore = .{},
    delivery: Delivery,
    role: ClientRole = .undecided,
    read_pending: bool = false,
    send_pending: bool = false,
    closing: bool = false,
    fn create(gpa: std.mem.Allocator, key: ClientKey, connection: core.transport.SocketChannel) !*ClientSession {
        const receive_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
        errdefer gpa.free(receive_buffer);
        var delivery = try Delivery.init(gpa);
        errdefer delivery.deinit(gpa);
        const session = try gpa.create(ClientSession);
        session.* = .{
            .key = key,
            .connection = connection,
            .receive_buffer = receive_buffer,
            .delivery = delivery,
        };
        return session;
    }

    fn active(session: *const ClientSession) bool {
        return !session.closing and session.connection.isActive();
    }

    fn deinit(session: *ClientSession, io: Io, gpa: std.mem.Allocator) void {
        std.debug.assert(!session.read_pending and !session.send_pending);
        session.connection.deinit(io);
        session.attachments.deinit();
        session.delivery.deinit(gpa);
        gpa.free(session.receive_buffer);
    }
};

const ClientStore = struct {
    items: [max_clients]?*ClientSession = @splat(null),
    count: usize = 0,
    next_id: u64 = 1,
    next_generation: u64 = 1,

    fn add(
        store: *ClientStore,
        gpa: std.mem.Allocator,
        connection: core.transport.SocketChannel,
    ) !*ClientSession {
        if (store.count == max_clients) return error.ClientLimitReached;
        if (store.next_id == 0 or store.next_id == std.math.maxInt(u64) or
            store.next_generation == 0 or store.next_generation == std.math.maxInt(u64))
            return error.ClientIdentityExhausted;
        const key: ClientKey = .{
            .id = store.next_id,
            .generation = store.next_generation,
        };
        for (&store.items) |*slot| {
            if (slot.* != null) continue;
            const session = try ClientSession.create(gpa, key, connection);
            slot.* = session;
            store.next_id += 1;
            store.next_generation += 1;
            store.count += 1;
            return session;
        }
        unreachable;
    }

    fn resolve(store: *ClientStore, key: ClientKey) ?*ClientSession {
        for (&store.items) |*slot| {
            const session = slot.* orelse continue;
            if (session.key.id == key.id and session.key.generation == key.generation)
                return session;
        }
        return null;
    }

    fn remove(store: *ClientStore, io: Io, gpa: std.mem.Allocator, key: ClientKey) bool {
        for (&store.items) |*slot| {
            const session = slot.* orelse continue;
            if (session.key.id != key.id or session.key.generation != key.generation)
                continue;
            session.deinit(io, gpa);
            gpa.destroy(session);
            slot.* = null;
            store.count -= 1;
            return true;
        }
        return false;
    }

    fn deinit(store: *ClientStore, io: Io, gpa: std.mem.Allocator) void {
        for (&store.items) |*slot| {
            if (slot.*) |session| {
                session.connection.shutdown(io);
                std.debug.assert(!session.read_pending and !session.send_pending);
                session.deinit(io, gpa);
                gpa.destroy(session);
            }
            slot.* = null;
        }
        store.count = 0;
    }
};

const GeometryLease = struct {
    workspace: schema.WorkspaceLocation,
    owner: ClientKey,
};

pub fn serve(io: Io, gpa: std.mem.Allocator, endpoint: []const u8, options: ServeOptions) !void {
    return serveInternal(io, gpa, endpoint, options);
}

/// Deterministic integration seam proving that PTY input remains independent
/// while a pane's bounded ingest actor is occupied. Production entry points
/// never install this gate.
pub const IngestTestGate = struct {
    entered: *Io.Queue(u8),
    release: *Io.Queue(u8),
    claimed: std.atomic.Value(bool) = .init(false),

    fn wait(gate: *IngestTestGate, io: Io) !void {
        if (gate.claimed.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
        try gate.entered.putOne(io, 0);
        _ = try gate.release.getOne(io);
    }
};

pub const LaunchTestFault = pane_launcher_mod.LaunchTestFault;

/// Infrastructure and orchestration state for one running runtime instance.
/// Authoritative semantic state lives in `model`; clients, event machinery,
/// workers and external resources remain server infrastructure.
const Server = struct {
    io: Io,
    gpa: std.mem.Allocator,
    heap: *diagnostics.Heap,
    select: *Io.Select(RuntimeEvent),
    history_service: *history.Service,
    child_environment: *const pty.Environment,
    inherited_environment: std.process.Environ,
    proxy: ?*proxy_mod.Proxy,
    agent_description_options: ?AgentDescriptionOptions,
    agent_description_pending: bool = false,
    launch_fault: ?*LaunchTestFault,
    clients: *ClientStore,
    handshake_slot: ?core.transport.SocketChannel = null,
    handshake_pending: bool = false,
    shutdown: shutdown_mod.State = .{},
    geometry_leases: [max_workspaces]?GeometryLease = @splat(null),
    model: RuntimeModel,
    system_metrics: system_metrics_mod.Sampler = .{},
    metrics: RuntimeMetrics,

    fn collect(server: *Server) void {
        server.collectFinished();
    }

    fn revokePaneCredential(server: *Server, pane: *Pane) void {
        if (server.proxy) |proxy| proxy.revokePane(pane.key());
    }

    fn workspaceRepository(server: *Server) WorkspaceRepository {
        return WorkspaceRepository.init(&server.model.workspaces, server.gpa);
    }

    fn workspaceReader(server: *const Server) workspace_mod.Reader {
        return workspace_mod.Reader.init(&server.model.workspaces);
    }

    /// Starts a pane and returns only after the runtime can observe both its
    /// output and exit. Client attachment and response delivery happen later.
    fn launchPane(server: *Server, location: schema.TabLocation, size: schema.TerminalSize, launch: schema.LaunchView, launch_cwd: []const u8, workspace_path: []const u8) !*Pane {
        var launcher: PaneLauncher(RuntimeEvent) = .{
            .io = server.io,
            .gpa = server.gpa,
            .select = server.select,
            .history_service = server.history_service,
            .child_environment = server.child_environment,
            .inherited_environment = server.inherited_environment,
            .proxy = server.proxy,
            .panes = &server.model.panes,
            .launch_fault = server.launch_fault,
        };
        const fresh = try launcher.launch(location, size, launch, launch_cwd, workspace_path);
        server.model.agents.touch();
        return fresh;
    }

    /// Reaps panes whose child exited and which no actor still borrows, then
    /// closes tabs that ran out of panes. Spans three stores, which is why it
    /// lives on the server rather than on any one of them.
    fn collectFinished(server: *Server) void {
        const store = &server.model.panes;
        var workspaces = server.workspaceRepository();

        if (store.exited_count == 0) {
            return;
        }

        for (&store.items) |*slot| {
            const pane = slot.* orelse continue;

            if (!pane.readyToDestroy()) {
                continue;
            }

            for (&server.clients.items) |*client_slot| {
                const client = client_slot.* orelse continue;
                if (client.attachments.find(pane.id) != null) {
                    break;
                }
            } else {
                const location = pane.location;
                store.index.remove(schema.id.raw(pane.id));
                store.exited_count -= 1;
                slot.* = null;
                store.count -= 1;

                if (!server.model.agents.remove(pane.key())) {
                    server.model.agents.touch();
                }

                server.revokePaneCredential(pane);
                pane.destroy();

                if (!store.hasAt(location) and workspaces.reader().contains(location)) {
                    const removed = workspace_mod.removeTab(&workspaces, location).?;
                    server.publishLifecycleTabRemoved(removed);
                }

                server.completeEmptyWorkspaceDepartures(location.workspace);
            }
        }
    }

    fn dropClient(server: *Server, key: ClientKey) void {
        const session = server.clients.resolve(key) orelse return;
        if (!session.closing) {
            session.closing = true;
            session.connection.shutdown(server.io);
            session.attachments.deinit();
            session.delivery.close();
            server.releaseGeometry(key);
            server.collect();
            // Deliver the resync notices now rather than on the next tick.
            // Re-entry from a pump failure is bounded: every dropClient marks
            // its session closing, and closing sessions are never pumped.
            server.pumpAll();
        }
        server.finalizeClient(key);
    }

    fn finalizeClient(server: *Server, key: ClientKey) void {
        const session = server.clients.resolve(key) orelse return;
        if (!session.closing or session.read_pending or session.send_pending) return;
        _ = server.clients.remove(server.io, server.gpa, key);
    }

    fn holdsGeometry(server: *Server, key: ClientKey, workspace: schema.WorkspaceLocation) bool {
        for (&server.geometry_leases) |*slot| {
            const lease = slot.* orelse continue;
            if (!std.meta.eql(lease.workspace, workspace)) continue;
            return std.meta.eql(lease.owner, key);
        }
        for (&server.geometry_leases) |*slot| {
            if (slot.* != null) continue;
            slot.* = .{ .workspace = workspace, .owner = key };
            return true;
        }
        return false;
    }

    fn releaseGeometry(server: *Server, key: ClientKey) void {
        for (&server.geometry_leases) |*slot| {
            const lease = slot.* orelse continue;
            if (!std.meta.eql(lease.owner, key)) continue;
            slot.* = null;
            // The lease is free but the runtime does not know any surviving
            // client's size. Resync the observers so one re-offers its
            // geometry and takes the lease over; without this the pane keeps
            // the departed client's size until an unrelated resize.
            server.notifyWorkspaceChanged(key, lease.workspace);
        }
    }

    fn releaseGeometryFor(server: *Server, key: ClientKey, workspace: schema.WorkspaceLocation) void {
        for (&server.geometry_leases) |*slot| {
            const lease = slot.* orelse continue;
            if (std.meta.eql(lease.owner, key) and std.meta.eql(lease.workspace, workspace)) {
                slot.* = null;
                server.notifyWorkspaceChanged(key, workspace);
            }
        }
    }

    fn notifyWorkspaceChanged(server: *Server, origin: ClientKey, workspace: schema.WorkspaceLocation) void {
        server.notifyWorkspaceChangedWithFallback(origin, workspace, null);
    }

    fn notifyWorkspaceClosed(server: *Server, origin: ClientKey, workspace: schema.WorkspaceLocation, previous_workspace: ?schema.WorkspaceId) void {
        server.notifyWorkspaceChangedWithFallback(origin, workspace, previous_workspace);
    }

    fn notifyWorkspaceChangedWithFallback(server: *Server, origin: ClientKey, workspace: schema.WorkspaceLocation, previous_workspace: ?schema.WorkspaceId) void {
        for (&server.clients.items) |*slot| {
            const session = slot.* orelse continue;

            if (std.meta.eql(session.key, origin) or !session.active()) {
                continue;
            }

            if (session.attachments.observes(workspace)) {
                session.delivery.responses.resync_workspace = workspace;
                session.delivery.responses.resync_previous_workspace = previous_workspace;
            }
        }
    }

    fn detachSessionPane(server: *Server, session: *ClientSession, pane_id: schema.PaneId) ?attachment_mod.PaneDetached {
        const detached = session.attachments.detach(pane_id) orelse return null;
        server.completeSessionWorkspaceDeparture(session, detached);
        return detached;
    }

    fn completeSessionWorkspaceDeparture(server: *Server, session: *ClientSession, detached: attachment_mod.PaneDetached) void {
        if (!detached.last_attachment) {
            return;
        }

        const left_workspace = session.attachments.leaveWorkspace(detached.workspace);
        std.debug.assert(left_workspace);

        if (!left_workspace) {
            return;
        }

        server.releaseGeometryFor(session.key, detached.workspace);
    }

    /// Completes departures deferred by `pane_exited` only after every pane
    /// that can still publish lifecycle changes for the workspace is reaped.
    fn completeEmptyWorkspaceDepartures(server: *Server, workspace: schema.WorkspaceLocation) void {
        if (server.hasPendingExitedPane(workspace)) {
            return;
        }

        for (&server.clients.items) |*slot| {
            const session = slot.* orelse continue;

            if (session.attachments.len() != 0 or !session.attachments.observes(workspace)) {
                continue;
            }

            const left_workspace = session.attachments.leaveWorkspace(workspace);
            std.debug.assert(left_workspace);

            if (left_workspace) {
                server.releaseGeometryFor(session.key, workspace);
            }
        }
    }

    fn hasPendingExitedPane(server: *const Server, workspace: schema.WorkspaceLocation) bool {
        for (server.model.panes.items) |slot| {
            const pane = slot orelse continue;

            if (pane.exit != null and std.meta.eql(pane.location.workspace, workspace)) {
                return true;
            }
        }

        return false;
    }

    /// Delivers an automatic tab-removal fact to every client that still
    /// observes its workspace. Queue saturation records snapshot recovery.
    fn publishLifecycleTabRemoved(server: *Server, removed: workspace_mod.TabRemoved) void {
        for (&server.clients.items) |*client_slot| {
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

    fn publishNotification(server: *Server, notification: schema.Notification) u8 {
        const pending = PendingNotification.init(notification);
        var delivered: u8 = 0;

        for (&server.clients.items) |*slot| {
            const recipient = slot.* orelse continue;
            if (!recipient.active() or recipient.role != .ui) continue;
            if (recipient.delivery.responses.pushNotification(pending)) delivered += 1;
        }

        return delivered;
    }

    fn publishAgentSound(server: *Server, notification: schema.AgentSoundNotification) void {
        for (&server.clients.items) |*slot| {
            const recipient = slot.* orelse continue;
            if (!recipient.active() or recipient.role != .ui) continue;
            _ = recipient.delivery.responses.pushAgentSound(notification);
        }
    }

    fn scheduleAgentDescription(server: *Server) void {
        const options = server.agent_description_options orelse return;
        if (server.agent_description_pending) return;
        var job = server.model.agents.nextDescriptionJob() orelse return;
        defer std.crypto.secureZero(u8, &job.query);
        server.select.concurrent(
            .agent_description,
            agent_mod.description.generate,
            .{
                server.io,
                server.gpa,
                agent_mod.description.Command{
                    .arguments = options.arguments,
                    .timeout_ms = options.timeout_ms,
                },
                job,
            },
        ) catch {
            const failed: agent_mod.description.Result = .{
                .pane = job.pane,
                .session_id = job.session_id,
                .status = .failed,
            };
            if (server.model.agents.finishDescription(&failed))
                _ = server.history_service.setSessionTitle(
                    server.io,
                    failed.session_id,
                    "",
                    .telar,
                    .failed,
                );
            server.pumpAll();
            return;
        };
        server.agent_description_pending = true;
    }

    fn handleAgentDescriptionEvent(
        server: *Server,
        result: agent_mod.description.Result,
    ) void {
        server.agent_description_pending = false;
        if (server.model.agents.finishDescription(&result)) {
            _ = server.history_service.setSessionTitle(
                server.io,
                result.session_id,
                if (result.status == .success) result.titleSlice() else "",
                if (result.status == .success) .generated else .telar,
                if (result.status == .success) .ready else .failed,
            );
        }
        server.scheduleAgentDescription();
        server.pumpAll();
    }

    fn pumpAll(server: *Server) void {
        for (&server.clients.items) |*slot| {
            const session = slot.* orelse continue;
            const key = session.key;
            server.pump(session) catch server.dropClient(key);
        }
        for (server.model.panes.items) |slot| {
            const pane = slot orelse continue;
            server.settlePaneDamage(pane);
        }
    }

    fn settlePaneDamage(server: *Server, pane: *Pane) void {
        if (pane.render_pending) return;
        for (&server.clients.items) |*slot| {
            const session = slot.* orelse continue;
            const attachment = session.attachments.find(pane.id) orelse continue;
            if (attachment.observedCellRevision() != pane.cell_revision) return;
        }
        @memset(pane.damaged_rows, false);
        pane.dirty = false;
    }

    fn shutdownDelivered(server: *const Server) bool {
        if (!server.shutdown.isRequested()) {
            return false;
        }

        for (&server.clients.items) |*slot| {
            const session = slot.* orelse continue;
            if (!session.closing and
                (session.delivery.stopping() or session.send_pending))
            {
                return false;
            }
        }

        return true;
    }

    fn pump(server: *Server, session: *ClientSession) !void {
        if (!session.active() or session.send_pending) return;
        const prepared = (try session.delivery.prepare(
            server.io,
            &session.attachments,
            .{
                .panes = &server.model.panes,
                .workspaces = server.workspaceReader(),
                .agents = &server.model.agents,
                .system_metrics = &server.system_metrics,
                .proxy_active = server.proxy != null,
                .home = server.inherited_environment.getPosix("HOME"),
            },
            &server.metrics,
        )) orelse return;
        startSessionSend(server.io, server.select, session, prepared.payload) catch |err| {
            session.delivery.abort(prepared);
            return err;
        };
        session.delivery.commit(prepared, &session.attachments, &server.metrics);
    }

    /// Applies one decoded client command. Domain rejection is represented by
    /// `request_failed`; commands for an attachment that has already gone are
    /// counted and ignored. Therefore an error return is an infrastructure
    /// failure, never ordinary client or lifecycle state.
    /// Entrypoint for one completed client socket read. It owns session
    /// validation, decode, dispatch, response pumping and read rescheduling.
    fn handleClientMessageEvent(server: *Server, event: ClientMessageEvent) !bool {
        const session = server.clients.resolve(event.client) orelse {
            server.metrics.stale_client_messages += 1;
            return false;
        };
        session.read_pending = false;
        if (session.closing) {
            server.finalizeClient(event.client);
            return false;
        }
        const payload = event.result catch {
            server.dropClient(event.client);
            return false;
        };
        const decode_started = diagnostics.now(server.io);
        const message = schema.decodeClient(payload) catch {
            server.dropClient(event.client);
            return false;
        };
        if (comptime diagnostics.enabled) {
            server.metrics.client_messages += 1;
            server.metrics.decode.observe(
                diagnostics.elapsed(decode_started, diagnostics.now(server.io)),
            );
        }
        if (session.role == .undecided) {
            session.role = switch (client_request_router.classify(std.meta.activeTag(message))) {
                .ui => .ui,
                .control => .control,
            };
        }

        server.dispatchClientMessage(session, message) catch {
            server.dropClient(event.client);
            return false;
        };
        server.pump(session) catch {
            server.dropClient(event.client);
            return false;
        };
        if (!server.shutdown.isRequested()) {
            startSessionRead(server.io, server.select, session) catch
                server.dropClient(event.client);
            return false;
        }
        server.pumpAll();
        return server.shutdownDelivered();
    }

    fn handlePaneOutputEvent(server: *Server, event: PaneOutputEvent, ingest_gate: ?*IngestTestGate) !void {
        var context: PaneOutputRuntime = .{ .server = server, .ingest_gate = ingest_gate };
        var pipeline = paneOutputPipeline(&context);
        return pipeline.handle(event);
    }

    /// Entrypoint for completed VT ingestion. It exposes the new cell/media
    /// state to attached clients and schedules the pane's next PTY read.
    fn handlePaneIngestedEvent(server: *Server, event: PaneIngestEvent) !void {
        const active = server.model.panes.resolve(event.pane) orelse {
            server.metrics.stale_pane_events += 1;
            return;
        };
        active.completeOutputIngest();
        const stats = event.result catch {
            _ = active.requestClose();
            active.finishPtyOutput();
            server.collect();
            return;
        };
        if (comptime diagnostics.enabled) {
            server.metrics.ingest.observe(stats.elapsed_ns);
        }
        retirePaneOnFailure(active, active.applyPendingResize()) catch {};
        try schedulePaneObservation(server.select, active);
        try schedulePaneMedia(server.select, active);
        for (&server.clients.items) |*slot| {
            const client = slot.* orelse continue;
            if (client.attachments.find(active.id)) |attachment| {
                _ = attachment.resizeIfNeeded() catch {
                    _ = server.detachSessionPane(client, active.id);
                };
            }
        }
        try schedulePaneResponse(server, active);
        const output_started = active.beginPtyOutputRead();
        std.debug.assert(output_started);
        server.select.concurrent(.pane_output, pane_launcher_mod.readPane, .{ server.io, active }) catch |err| {
            active.cancelPtyOutputRead();
            return err;
        };
        server.collect();
        server.pumpAll();
    }

    fn handleAcceptedEvent(
        server: *Server,
        result: anyerror!core.transport.SocketChannel,
        listener: *transport.local.LocalListener,
    ) !void {
        var accepted = result catch {
            try server.select.concurrent(.accepted, acceptClient, .{ server.io, listener });
            return;
        };
        if (server.shutdown.isRequested()) {
            accepted.deinit(server.io);
            return;
        }
        try server.select.concurrent(.accepted, acceptClient, .{ server.io, listener });
        // The handshake runs in its own actor so a connection that never says
        // hello cannot hold the accept pipeline hostage. One slot, newest
        // wins: an arriving client evicts a stalled handshake and retries into
        // the freed slot.
        if (server.handshake_pending) {
            if (server.handshake_slot) |*pending| pending.shutdown(server.io);
            accepted.deinit(server.io);
            return;
        }
        server.handshake_slot = accepted;
        server.handshake_pending = true;
        server.select.concurrent(.handshaken, handshakeClient, .{
            server.io,
            &server.handshake_slot.?,
        }) catch {
            server.handshake_pending = false;
            server.handshake_slot.?.deinit(server.io);
            server.handshake_slot = null;
        };
    }

    fn handleHandshakenEvent(server: *Server, result: anyerror!void) void {
        server.handshake_pending = false;
        var negotiated = server.handshake_slot.?;
        server.handshake_slot = null;
        result catch {
            negotiated.deinit(server.io);
            return;
        };
        if (server.shutdown.isRequested()) {
            negotiated.deinit(server.io);
            return;
        }
        const session = server.clients.add(server.gpa, negotiated) catch {
            negotiated.deinit(server.io);
            return;
        };
        startSessionRead(server.io, server.select, session) catch
            server.dropClient(session.key);
    }

    fn handleClientSentEvent(server: *Server, event: ClientSentEvent) bool {
        const session = server.clients.resolve(event.client) orelse {
            server.metrics.stale_client_messages += 1;
            return false;
        };
        session.send_pending = false;
        if (session.closing) {
            server.finalizeClient(event.client);
            return server.shutdownDelivered();
        }
        const completion = session.delivery.complete(event.result);
        if (completion.close_client) {
            server.dropClient(event.client);
            return server.shutdownDelivered();
        }
        if (completion.detach_pane) |pane_id| {
            _ = session.attachments.detach(pane_id);
            server.collect();
        }
        if (session.delivery.shouldCloseAfterReply() and
            !server.shutdown.isRequested())
        {
            server.dropClient(event.client);
            return false;
        }
        server.pump(session) catch server.dropClient(event.client);
        if (!server.shutdown.isRequested()) {
            return false;
        }

        server.pumpAll();
        return server.shutdownDelivered();
    }

    fn handleHistoryResponseEvent(
        server: *Server,
        response_result: anyerror!history.Response,
    ) !void {
        const response = response_result catch return;
        try server.select.concurrent(.history_response, history.receiveResponse, .{
            server.io,
            server.history_service,
        });
        switch (response) {
            .query_result => |result| {
                const session = server.clients.resolve(result.origin.client) orelse {
                    result.deinit();
                    return;
                };
                session.delivery.setCloseAfterReply(result.origin.close_after_reply);
                session.delivery.responses.push(.{ .history_result = result }) catch
                    result.deinit();
            },
            .failed => |failure| {
                const session = server.clients.resolve(failure.origin.client) orelse return;
                session.delivery.setCloseAfterReply(failure.origin.close_after_reply);
                queueFailure(
                    &session.delivery.responses,
                    failure.request_id,
                    .internal,
                    failure.message,
                ) catch {};
            },
        }
        server.pumpAll();
    }

    /// Applies one proxy observation as agent-lifecycle evidence for the live pane
    /// generation that authorized the intercepted connection.
    ///
    /// Successful receives are rearmed before processing. Receive failures,
    /// observations for retired panes, and auxiliary requests do not alter agent
    /// state. Accepted observations may update the projected agent state, schedule
    /// description work, and make a new snapshot available for client delivery.
    fn handleProxyEvent(server: *Server, event_result: anyerror!proxy_mod.Observation) !void {
        const event = event_result catch return;

        if (server.proxy) |proxy|
            try server.select.concurrent(
                .proxy_event,
                proxy_mod.Proxy.receive,
                .{ proxy, server.io },
            );

        const active = server.model.panes.resolve(event.pane) orelse {
            server.metrics.stale_pane_events += 1;
            return;
        };

        if (comptime diagnostics.enabled) {
            server.metrics.proxy_observations +|= 1;
        }

        _ = server.model.agents.observeProxy(.{
            .identity = agent_mod.Identity.fromPane(active),
            .provider = event.provider,
            .phase = switch (event.phase) {
                .request_started => .request_started,
                .auxiliary_request_started => return,
                .response_activity => .response_activity,
                .provider_turn_completed => .provider_turn_completed,
                .response_finished => .response_finished,
                .request_failed => .request_failed,
            },
            .exchange = .{
                .protocol = switch (event.protocol) {
                    .http11 => .http11,
                    .h2 => .h2,
                    .upgraded => .upgraded,
                },
                .connection_id = event.connection_id,
                .stream_id = event.stream_id,
            },
            .observed_at_ms = event.observed_at_ms,
        });

        server.scheduleAgentDescription();
        server.pumpAll();
    }

    fn handleAgentTickEvent(server: *Server, result: anyerror!void) !void {
        result catch return;
        try server.select.concurrent(.agent_tick, waitForAgentTick, .{server.io});
        _ = server.model.agents.expire(Io.Timestamp.now(server.io, .real).toMilliseconds());
        server.pumpAll();
    }

    fn handleMetricsTickEvent(server: *Server, result: anyerror!void) !void {
        result catch return;
        try server.select.concurrent(.metrics_tick, waitForMetricsTick, .{server.io});
        server.system_metrics.sample();
        server.pumpAll();
    }

    fn handlePaneInputWrittenEvent(server: *Server, event: PaneInputEvent) !void {
        var input_pump = paneInputPump(server);
        return input_pump.complete(event);
    }

    fn handlePaneResponseWrittenEvent(server: *Server, event: PaneResponseEvent) !void {
        var response_pump = paneResponsePump(server);
        return response_pump.complete(event);
    }

    fn handlePaneObservedEvent(server: *Server, event: PaneObservationEvent) !void {
        const active = server.model.panes.resolve(event.pane) orelse {
            server.metrics.stale_pane_events += 1;
            return;
        };
        active.actorFinished();
        active.history_observer.finishSealed();
        if (active.updateObservedCwd()) server.model.agents.touch();
        if (comptime diagnostics.enabled) {
            if (event.process_probe.inspected) {
                server.metrics.agent_process_inspections +|= 1;
                if (event.process_probe.cache.provider == .unknown)
                    server.metrics.agent_process_misses +|= 1;
            }
        }
        const previous_process = active.agent_process_cache;
        active.agent_process_cache = event.process_probe.cache;
        if (!std.mem.eql(
            u8,
            previous_process.name(),
            active.agent_process_cache.name(),
        )) {
            active.foreground_revision +%= 1;
            if (active.foreground_revision == 0) active.foreground_revision = 1;
        }
        if (event.process_probe.changed) {
            const observed_at_ms = Io.Timestamp.now(server.io, .real).toMilliseconds();
            if (event.process_probe.cache.provider != .unknown) {
                _ = server.model.agents.observeProcess(.{
                    .identity = agent_mod.Identity.fromPane(active),
                    .provider = event.process_probe.cache.provider,
                    .process_id = event.process_probe.cache.process_group_id.?,
                    .observed_at_ms = observed_at_ms,
                });
            } else if (agent_process.shellForeground(
                event.process_probe.cache,
                active.session.pid,
            )) {
                _ = server.model.agents.remove(active.key());
            } else if (previous_process.provider != .unknown) {
                _ = server.model.agents.clearProcess(active.key());
            }
        }
        if (comptime diagnostics.enabled) {
            server.metrics.history_candidate_input_bytes +|= event.stats.input_bytes;
            server.metrics.history_captured +|= event.stats.captured;
            server.metrics.history_dropped +|= event.stats.dropped;
            if (event.stats.failed) server.metrics.history_observation_failures +|= 1;
            if (event.stats.reset) server.metrics.history_observation_resets +|= 1;
        }
        if (event.stats.agent_signal) |signal| if (!agent_process.shellForeground(
            active.agent_process_cache,
            active.session.pid,
        )) {
            const identity = agent_mod.Identity.fromPane(active);
            const previous_status = server.model.agents.projectedStatus(identity.key);
            const changed = server.model.agents.observeScreen(.{
                .identity = identity,
                .signal = .{
                    .provider = signal.provider,
                    .status = switch (signal.status) {
                        .working => .working,
                        .blocked => .blocked,
                        .ready => .ready,
                    },
                    .confidence = signal.confidence,
                    .identity_confirmed = signal.identity_confirmed,
                    .ready_confirmed = signal.ready_confirmed,
                },
                .observed_at_ms = Io.Timestamp.now(server.io, .real).toMilliseconds(),
            });
            if (changed) if (agentSoundForTransition(
                previous_status,
                server.model.agents.projectedStatus(identity.key),
            )) |sound| server.publishAgentSound(.{
                .pane_id = identity.key.id,
                .pane_generation = identity.key.generation,
                .sound = sound,
            });
        };
        server.scheduleAgentDescription();
        try schedulePaneObservation(server.select, active);
        server.collect();
        server.pumpAll();
    }

    fn handlePaneMediaEvent(server: *Server, event: PaneMediaEvent) !void {
        const active = server.model.panes.resolve(event.pane) orelse {
            server.metrics.stale_pane_events += 1;
            return;
        };
        active.actorFinished();
        active.media.finishSealed();
        if (comptime diagnostics.enabled) {
            server.metrics.media_bytes +|= event.stats.output_bytes;
            server.metrics.media_discarded_frames +|= event.stats.discarded_frames;
            server.metrics.media_unavailable_frames +|= event.stats.unavailable_frames;
            server.metrics.media_forwarded_frames +|= event.stats.forwarded_frames;
            if (event.stats.failed) server.metrics.media_failures +|= 1;
            if (event.stats.reset) server.metrics.media_resets +|= 1;
        }
        enforceGraphicsQuotas(server.io, active);
        active.observeGraphicsDamage();
        active.graphics_present =
            active.media.terminal.screens.active.kitty_images.images.count() != 0;
        if (event.stats.reset) {
            for (&server.clients.items) |*slot| {
                const client = slot.* orelse continue;
                _ = client.attachments.requestGraphicsSnapshot(active.id);
            }
        }
        // Freeze the next transfer while the media actor is idle so the send
        // loop can drain it whenever the transport becomes ready.
        for (&server.clients.items) |*slot| {
            const client = slot.* orelse continue;
            const attachment = client.attachments.find(active.id) orelse continue;
            if (attachment.hasFrozenGraphics() or attachment.graphicsCaughtUp()) continue;
            const staged = attachment.stageGraphics(
                client.attachments.availableGraphicsCredit(),
            ) catch blk: {
                attachment.abandonGraphics();
                break :blk .idle;
            };
            switch (staged) {
                .staged => if (comptime diagnostics.enabled) {
                    server.metrics.graphics_transfers_staged +|= 1;
                },
                .blocked, .idle => {},
            }
        }
        try schedulePaneResponse(server, active);
        server.pumpAll();
        try schedulePaneMedia(server.select, active);
        server.collect();
        server.pumpAll();
    }

    fn handlePaneExitEvent(server: *Server, event: PaneExitEvent) !void {
        const active = server.model.panes.resolve(event.pane) orelse {
            server.metrics.stale_pane_events += 1;
            return;
        };
        active.actorFinished();
        active.wait_pending = false;
        active.exit = pane_launcher_mod.exitOrSynthetic(event.result);
        _ = server.model.agents.remove(active.key());
        server.revokePaneCredential(active);
        server.model.panes.exited_count += 1;
        if (active.launch_state == .aborting) {
            server.collect();
            server.pumpAll();
            return;
        }
        if (active.output_done) {
            active.queueExitedHistory(active.exit.?);
            try schedulePaneObservation(server.select, active);
        }
        server.collect();
        server.pumpAll();
    }

    fn handleTelemetryTickEvent(server: *Server, result: anyerror!void, telemetry: *diagnostics.Sink, buffer: *[12288]u8, write_pending: *bool) void {
        result catch {
            telemetry.deinit(server.io);
            return;
        };
        if (!telemetry.available()) return;
        server.select.concurrent(.telemetry_tick, diagnostics.waitForTick, .{server.io}) catch {
            telemetry.deinit(server.io);
            return;
        };
        if (write_pending.*) return;

        var attachment_stores: [max_clients]*const AttachmentStore = undefined;
        var attachment_store_count: usize = 0;
        var response_queue_depth: usize = 0;
        var response_queue_high_water: usize = 0;
        var response_queue_dropped: u64 = 0;
        for (&server.clients.items) |*slot| {
            const session = slot.* orelse continue;
            attachment_stores[attachment_store_count] = &session.attachments;
            attachment_store_count += 1;
            response_queue_depth += session.delivery.responses.len;
            response_queue_high_water += session.delivery.responses.high_water;
            response_queue_dropped +|= session.delivery.responses.dropped;
        }
        const proxy_metrics = if (server.proxy) |proxy|
            proxy.metrics()
        else
            proxy_mod.MetricsSnapshot{};
        const workspaces = server.workspaceReader();

        const line = formatRuntimeTelemetry(
            buffer,
            server.io,
            &server.metrics,
            attachment_stores[0..attachment_store_count],
            server.clients.count,
            workspaces.count(),
            workspaces.totalTabs(),
            &server.model.panes,
            server.history_service,
            response_queue_depth,
            response_queue_high_water,
            response_queue_dropped,
            server.proxy != null,
            proxy_metrics.active_connections,
            proxy_metrics.queued_events,
            proxy_metrics.event_queue_high_water,
            proxy_metrics.dropped_events,
            proxy_metrics.rejected_connections,
            proxy_metrics.invalid_authorization_rejections,
            proxy_metrics.unknown_credential_rejections,
            proxy_metrics.connection_limit_drops,
            proxy_metrics.h2_decode_failures,
            proxy_metrics.passthrough_connections,
            proxy_metrics.upstream_connect_failures,
            proxy_metrics.tls_context_failures,
            proxy_metrics.tls_upstream_handshake_failures,
            proxy_metrics.tls_downstream_handshake_failures,
            proxy_metrics.tls_mint_failures,
            server.heap,
        ) catch return;
        write_pending.* = true;
        server.select.concurrent(.telemetry_written, writeDiagnostics, .{
            server.io,
            telemetry,
            line,
        }) catch {
            write_pending.* = false;
            telemetry.deinit(server.io);
        };
    }

    fn handleTelemetryWrittenEvent(server: *Server, result: anyerror!void, telemetry: *diagnostics.Sink, write_pending: *bool) void {
        write_pending.* = false;
        result catch telemetry.deinit(server.io);
    }

    fn dispatchClientMessage(server: *Server, session: *ClientSession, message: schema.ClientMessage) !void {
        var context = ClientRequestContext.init(server, session);
        const router = ClientRequestRouter.init(&context);

        return router.route(message);
    }
};

const ClientRequestContext = struct {
    server: *Server,
    session: *ClientSession,
    workspaces: WorkspaceRepository,

    fn init(server: *Server, session: *ClientSession) ClientRequestContext {
        return .{
            .server = server,
            .session = session,
            .workspaces = server.workspaceRepository(),
        };
    }
};

const client_request_handlers: client_request_router.Handlers(ClientRequestContext) = .{
    .open_pane = routeOpenPane,
    .pane_input = routePaneInput,
    .pane_resize = routePaneResize,
    .frame_ack = routeFrameAck,
    .request_snapshot = routeRequestSnapshot,
    .detach_pane = routeDetachPane,
    .runtime_stop = routeRuntimeStop,
    .request_tab_snapshot = routeRequestTabSnapshot,
    .create_pane = routeCreatePane,
    .close_pane = routeClosePane,
    .query_history = routeQueryHistory,
    .request_workspace_snapshot = routeRequestWorkspaceSnapshot,
    .create_tab = routeCreateTab,
    .rename_tab = routeRenameTab,
    .close_tab = routeCloseTab,
    .move_tab = routeMoveTab,
    .request_graphics_snapshot = routeRequestGraphicsSnapshot,
    .graphics_credit = routeGraphicsCredit,
    .configure_graphics = routeConfigureGraphics,
    .request_runtime_state = routeRequestRuntimeState,
    .create_workspace = routeCreateWorkspace,
    .rename_workspace = routeRenameWorkspace,
    .set_pane_viewport = routeSetPaneViewport,
    .copy_selection = routeCopySelection,
    .show_notification = routeShowNotification,
};

const ClientRequestRouter = client_request_router.Router(ClientRequestContext, client_request_handlers);

fn routeOpenPane(request: *ClientRequestContext, open: schema.OpenPaneView) !void {
    const server = request.server;
    const session = request.session;
    var client_context: ClientLaunchContext = .{ .server = server, .session = session };
    var handler: open_pane_commands.OpenPaneHandler = .{
        .workspaces = &request.workspaces,
        .panes = .{
            .context = &client_context,
            .find = findOpenPane,
            .first = findFirstOpenPane,
            .launch = launchOpenPane,
            .prepare_view = prepareOpenPaneView,
            .attach = attachOpenPane,
        },
        .authority = .{
            .context = &client_context,
            .prepare = prepareOpenPaneLaunch,
        },
        .geometry = .{
            .context = &client_context,
            .acquire = acquireCreatedWorkspaceGeometry,
            .release = releaseCreatedWorkspaceGeometry,
        },
        .events = .{
            .context = &client_context,
            .publish = publishOpenPaneEvent,
        },
    };
    var controller = open_pane_controller.Controller.init(&session.delivery.responses, handler.executor());

    try controller.openPane(open);
}

fn routePaneInput(request: *ClientRequestContext, input: schema.PaneInput) !void {
    const server = request.server;
    var handler: pane_input_commands.PaneInputHandler = .{
        .io = server.io,
        .attachments = &request.session.attachments,
        .metrics = &server.metrics,
        .agent_input = if (server.agent_description_options != null) &server.model.agents else null,
        .scheduler = paneInputScheduler(server),
    };
    var controller = PaneInputController.init(&server.metrics, &handler);

    try controller.paneInput(input);
}

fn routePaneResize(request: *ClientRequestContext, resize: schema.PaneResize) !void {
    const server = request.server;
    const session = request.session;
    var resize_context: ClientAttachmentContext = .{ .server = server, .session = session };
    var handler: pane_resize_commands.PaneResizeHandler = .{
        .attachments = &session.attachments,
        .geometry = .{
            .context = &resize_context,
            .holds = clientHoldsWorkspaceGeometry,
            .release = releaseClientWorkspaceGeometry,
        },
        .scheduler = paneResizeScheduler(server),
    };
    var controller = PaneResizeController.init(&server.metrics, &handler);

    try controller.paneResize(resize);
}

fn routeFrameAck(request: *ClientRequestContext, ack: schema.FrameAck) !void {
    const server = request.server;
    var handler: frame_ack_commands.FrameAckHandler = .{
        .attachments = &request.session.attachments,
    };
    var controller = FrameAckController.init(server.io, &server.metrics, &handler);

    try controller.frameAck(ack);
}

fn routeRequestSnapshot(request: *ClientRequestContext, snapshot: schema.RequestSnapshot) !void {
    var handler: request_snapshot_commands.RequestCellSnapshotHandler = .{
        .attachments = &request.session.attachments,
    };
    var controller = RequestSnapshotController.init(&request.server.metrics, &handler);

    try controller.requestSnapshot(snapshot);
}

fn routeDetachPane(request: *ClientRequestContext, detach: schema.DetachPane) !void {
    const server = request.server;
    const session = request.session;
    var detach_context: ClientAttachmentContext = .{ .server = server, .session = session };
    var handler: detach_pane_commands.DetachPaneHandler = .{
        .attachments = .{
            .context = &detach_context,
            .detach = detachClientAttachment,
            .leave_workspace = leaveClientWorkspace,
        },
        .geometry = .{
            .context = &detach_context,
            .release = releaseClientWorkspaceGeometry,
        },
    };
    var controller = detach_pane_controller.Controller.init(handler.executor(), .{
        .context = &server.metrics,
        .record = recordStaleClientMessage,
    });

    try controller.detachPane(detach);
}

fn routeRuntimeStop(request: *ClientRequestContext) !void {
    var handler: runtime_stop_commands.RuntimeStopHandler = .{
        .shutdown = &request.server.shutdown,
        .notifications = runtimeStopNotifications(request.server),
    };
    var controller = runtime_stop_controller.Controller.init(handler.executor());

    controller.runtimeStop(request.session.key);
}

fn routeRequestTabSnapshot(request: *ClientRequestContext, snapshot: schema.RequestTabSnapshot) !void {
    var source_context: TabSnapshotSourceContext = .{
        .panes = &request.server.model.panes,
        .workspaces = &request.workspaces,
    };
    var handler: tab_snapshot_query.Handler = .{
        .source = .{
            .context = &source_context,
            .contains_tab = tabSnapshotContainsTab,
            .running_panes = tabSnapshotRunningPanes,
        },
    };
    var controller = tab_snapshot_controller.Controller.init(&request.session.delivery.responses, handler.executor());

    try controller.requestTabSnapshot(snapshot);
}

fn routeCreatePane(request: *ClientRequestContext, create: schema.CreatePaneView) !void {
    const server = request.server;
    const session = request.session;
    var client_context: ClientLaunchContext = .{ .server = server, .session = session };
    var event_context: WorkspaceEventContext = .{ .server = server, .origin = session.key };
    var handler: create_pane_commands.CreatePaneHandler = .{
        .workspaces = request.workspaces.reader(),
        .panes = .{
            .context = &server.model.panes,
            .has_running = createPaneHasRunning,
        },
        .authority = .{
            .context = &client_context,
            .prepare = prepareCreatePaneLaunch,
        },
        .launcher = .{
            .context = server,
            .launch = launchCreatedPane,
        },
        .attachment = .{
            .context = &client_context,
            .attach = attachCreatedPane,
        },
        .events = .{
            .context = &event_context,
            .publish = publishPaneLaunched,
        },
    };
    var controller = create_pane_controller.Controller.init(&session.delivery.responses, handler.executor());

    try controller.createPane(create);
}

fn routeClosePane(request: *ClientRequestContext, close: schema.ClosePane) !void {
    var handler: close_pane_commands.ClosePaneHandler = .{
        .panes = .{
            .context = &request.session.attachments,
            .request_close = requestAttachedPaneClose,
        },
    };
    var controller = close_pane_controller.Controller.init(&request.session.delivery.responses, handler.executor());

    try controller.closePane(close);
}

fn routeQueryHistory(request: *ClientRequestContext, query: schema.QueryHistory) !void {
    const server = request.server;
    const session = request.session;
    var service_context: HistoryQueryServiceContext = .{
        .io = server.io,
        .service = server.history_service,
    };
    var handler: history_query.Handler = .{
        .service = .{
            .context = &service_context,
            .submit_fn = submitHistoryQuery,
        },
    };
    var controller = history_query_controller.Controller.init(
        &session.delivery.responses,
        &server.metrics,
        handler.executor(),
    );

    try controller.queryHistory(.{
        .client = session.key,
        .close_after_reply = session.role == .control,
    }, query);
}

fn routeRequestWorkspaceSnapshot(request: *ClientRequestContext, snapshot: schema.RequestWorkspaceSnapshot) !void {
    var handler: workspace_snapshot_query.Handler = .{
        .workspaces = request.workspaces.reader(),
    };
    var controller = workspace_snapshot_controller.Controller.init(&request.session.delivery.responses, handler.executor());

    try controller.requestWorkspaceSnapshot(snapshot);
}

fn routeCreateTab(request: *ClientRequestContext, create: schema.CreateTabView) !void {
    const server = request.server;
    const session = request.session;
    var client_context: ClientLaunchContext = .{ .server = server, .session = session };
    var event_context: WorkspaceEventContext = .{ .server = server, .origin = session.key };
    var handler: create_tab_commands.CreateTabHandler = .{
        .workspaces = &request.workspaces,
        .authority = .{
            .context = &client_context,
            .prepare = prepareCreateTabLaunch,
        },
        .launcher = .{
            .context = server,
            .launch = launchCreatedTabPane,
        },
        .attachment = .{
            .context = &client_context,
            .attach = attachCreatedTab,
        },
        .events = .{
            .context = &event_context,
            .publish = publishTabCreated,
        },
    };
    var controller = create_tab_controller.Controller.init(&session.delivery.responses, handler.executor());

    try controller.createTab(create);
}

fn routeRenameTab(request: *ClientRequestContext, rename: schema.RenameTab) !void {
    const server = request.server;
    var event_context: WorkspaceEventContext = .{ .server = server, .origin = request.session.key };
    var handler: tab_commands.RenameTabHandler = .{
        .workspaces = &request.workspaces,
        .events = .{
            .context = &event_context,
            .publish = publishTabRenamed,
        },
    };
    var controller = tab_controller.Controller.init(&request.session.delivery.responses, handler.executor());

    try controller.renameTab(rename);
}

fn routeCloseTab(request: *ClientRequestContext, close: schema.CloseTab) !void {
    const server = request.server;
    var event_context: WorkspaceEventContext = .{ .server = server, .origin = request.session.key };
    var handler: close_tab_commands.CloseTabHandler = .{
        .workspaces = &request.workspaces,
        .panes = .{
            .context = &server.model.panes,
            .close_all = closeTabPanes,
        },
        .events = .{
            .context = &event_context,
            .publish = publishTabRemoved,
        },
    };
    var controller = close_tab_controller.Controller.init(&request.session.delivery.responses, handler.executor());

    try controller.closeTab(close);
}

fn routeMoveTab(request: *ClientRequestContext, move: schema.MoveTab) !void {
    const server = request.server;
    var event_context: WorkspaceEventContext = .{ .server = server, .origin = request.session.key };
    var handler: move_tab_commands.MoveTabHandler = .{
        .workspaces = &request.workspaces,
        .events = .{
            .context = &event_context,
            .publish = publishTabMoved,
        },
    };
    var controller = move_tab_controller.Controller.init(&request.session.delivery.responses, handler.executor());

    try controller.moveTab(move);
}

fn routeRequestGraphicsSnapshot(request: *ClientRequestContext, snapshot: schema.RequestGraphicsSnapshot) !void {
    var handler: request_graphics_snapshot_commands.RequestGraphicsSnapshotHandler = .{
        .attachments = &request.session.attachments,
    };
    var controller = RequestGraphicsSnapshotController.init(&request.server.metrics, &handler);

    try controller.requestGraphicsSnapshot(snapshot);
}

fn routeGraphicsCredit(request: *ClientRequestContext, credit: schema.GraphicsCredit) !void {
    var handler: graphics_credit_commands.ReturnGraphicsCreditHandler = .{
        .attachments = &request.session.attachments,
    };
    var controller = GraphicsCreditController.init(&request.server.metrics, &handler);

    try controller.graphicsCredit(credit);
}

fn routeConfigureGraphics(request: *ClientRequestContext, configure: schema.ConfigureGraphics) !void {
    var handler: graphics_configuration_commands.ConfigureGraphicsHandler = .{
        .attachments = &request.session.attachments,
    };
    var controller = GraphicsConfigurationController.init(&handler);

    try controller.configureGraphics(configure);
}

fn routeRequestRuntimeState(request: *ClientRequestContext) !void {
    var controller = RuntimeStateController.init(&request.session.delivery);

    controller.requestRuntimeState();
}

fn routeCreateWorkspace(request: *ClientRequestContext, create: schema.CreateWorkspaceView) !void {
    const server = request.server;
    const session = request.session;
    var client_context: ClientLaunchContext = .{ .server = server, .session = session };
    var event_context: WorkspaceEventContext = .{ .server = server, .origin = session.key };
    var handler: create_workspace_commands.CreateWorkspaceHandler = .{
        .workspaces = &request.workspaces,
        .authority = .{
            .context = &client_context,
            .prepare = prepareCreateWorkspaceLaunch,
        },
        .geometry = .{
            .context = &client_context,
            .acquire = acquireCreatedWorkspaceGeometry,
            .release = releaseCreatedWorkspaceGeometry,
        },
        .launcher = .{
            .context = server,
            .launch = launchCreatedWorkspacePane,
        },
        .attachment = .{
            .context = &client_context,
            .replace = replaceCreatedWorkspaceAttachments,
        },
        .events = .{
            .context = &event_context,
            .publish = publishWorkspaceCreated,
        },
    };
    var controller = create_workspace_controller.Controller.init(&session.delivery.responses, handler.executor());

    try controller.createWorkspace(create);
}

fn routeRenameWorkspace(request: *ClientRequestContext, rename: schema.RenameWorkspace) !void {
    var event_context: WorkspaceEventContext = .{
        .server = request.server,
        .origin = request.session.key,
    };
    var handler: rename_workspace_commands.RenameWorkspaceHandler = .{
        .workspaces = &request.workspaces,
        .events = .{
            .context = &event_context,
            .publish = publishWorkspaceRenamed,
        },
    };
    var controller = rename_workspace_controller.Controller.init(&request.session.delivery.responses, handler.executor());

    try controller.renameWorkspace(rename);
}

fn routeSetPaneViewport(request: *ClientRequestContext, viewport: schema.SetPaneViewport) !void {
    var handler: pane_viewport_commands.SetPaneViewportHandler = .{
        .attachments = &request.session.attachments,
    };
    var controller = PaneViewportController.init(&request.server.metrics, &handler);

    try controller.setPaneViewport(viewport);
}

fn routeCopySelection(request: *ClientRequestContext, selection: schema.CopySelection) !void {
    var handler: copy_selection_commands.CopySelectionHandler = .{
        .attachments = &request.session.attachments,
    };
    var controller = CopySelectionController.init(&request.server.metrics, &handler, &request.session.delivery);

    controller.copySelection(selection);
}

fn routeShowNotification(request: *ClientRequestContext, notification: schema.ShowNotification) !void {
    var handler: show_notification_commands.ShowNotificationHandler = .{
        .notifications = notificationPublisher(request.server),
    };
    var controller = show_notification_controller.Controller.init(
        &request.session.delivery.responses,
        handler.executor(),
        notificationDelivery(request.server),
    );

    try controller.showNotification(notification);
}

fn paneInputScheduler(server: *Server) pane_input_commands.Scheduler {
    return .{
        .context = server,
        .observation = entrypointScheduleObservation,
        .input = entrypointScheduleInput,
    };
}

fn paneResizeScheduler(server: *Server) pane_resize_commands.Scheduler {
    return .{
        .context = server,
        .observation = entrypointScheduleObservation,
        .media = entrypointScheduleMedia,
        .response = entrypointScheduleResponse,
    };
}

fn entrypointScheduleObservation(context: *anyopaque, pane: *Pane) !void {
    const server: *Server = @ptrCast(@alignCast(context));
    return schedulePaneObservation(server.select, pane);
}

fn entrypointScheduleMedia(context: *anyopaque, pane: *Pane) !void {
    const server: *Server = @ptrCast(@alignCast(context));
    return schedulePaneMedia(server.select, pane);
}

fn entrypointScheduleResponse(context: *anyopaque, pane: *Pane) !void {
    const server: *Server = @ptrCast(@alignCast(context));
    return schedulePaneResponse(server, pane);
}

fn entrypointScheduleInput(context: *anyopaque, pane: *Pane) !void {
    const server: *Server = @ptrCast(@alignCast(context));
    var input_pump = paneInputPump(server);
    return input_pump.schedule(pane);
}

const ClientLaunchContext = struct {
    server: *Server,
    session: *ClientSession,
};

const ClientAttachmentContext = struct {
    server: *Server,
    session: *ClientSession,
};

const WorkspaceEventContext = struct {
    server: *Server,
    origin: ClientKey,
};

const TabSnapshotSourceContext = struct {
    panes: *PaneStore,
    workspaces: *WorkspaceRepository,
};

const HistoryQueryServiceContext = struct {
    io: Io,
    service: *history.Service,
};

fn submitHistoryQuery(context: *anyopaque, query: history.Query) bool {
    const service: *HistoryQueryServiceContext = @ptrCast(@alignCast(context));
    return service.service.query(service.io, query);
}

fn tabSnapshotContainsTab(context: *anyopaque, location: schema.TabLocation) bool {
    const source: *TabSnapshotSourceContext = @ptrCast(@alignCast(context));
    return source.workspaces.reader().contains(location);
}

fn tabSnapshotRunningPanes(context: *anyopaque, location: schema.TabLocation) u16 {
    const source: *TabSnapshotSourceContext = @ptrCast(@alignCast(context));
    return source.panes.countAt(location);
}

fn requestAttachedPaneClose(context: *anyopaque, pane_id: schema.PaneId) ?bool {
    const attachments: *AttachmentStore = @ptrCast(@alignCast(context));
    const attachment = attachments.find(pane_id) orelse return null;
    return attachment.pane.requestClose();
}

fn createPaneHasRunning(context: *anyopaque, location: schema.TabLocation) bool {
    const panes: *PaneStore = @ptrCast(@alignCast(context));
    return panes.countAt(location) != 0;
}

fn detachClientAttachment(context: *anyopaque, pane_id: schema.PaneId) ?attachment_mod.PaneDetached {
    const client: *ClientAttachmentContext = @ptrCast(@alignCast(context));
    return client.session.attachments.detach(pane_id);
}

fn leaveClientWorkspace(context: *anyopaque, workspace: schema.WorkspaceLocation) bool {
    const client: *ClientAttachmentContext = @ptrCast(@alignCast(context));
    return client.session.attachments.leaveWorkspace(workspace);
}

fn clientHoldsWorkspaceGeometry(context: *anyopaque, workspace: schema.WorkspaceLocation) bool {
    const client: *ClientAttachmentContext = @ptrCast(@alignCast(context));
    return client.server.holdsGeometry(client.session.key, workspace);
}

fn releaseClientWorkspaceGeometry(context: *anyopaque, workspace: schema.WorkspaceLocation) void {
    const client: *ClientAttachmentContext = @ptrCast(@alignCast(context));
    client.server.releaseGeometryFor(client.session.key, workspace);
}

fn recordStaleClientMessage(context: *anyopaque) void {
    const metrics: *RuntimeMetrics = @ptrCast(@alignCast(context));
    metrics.stale_client_messages += 1;
}

fn findOpenPane(context: *anyopaque, pane_id: schema.PaneId) ?pane_mod.PaneLaunched {
    const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
    const pane = client.server.model.panes.findRunning(pane_id) orelse return null;

    if (pane.close_requested or pane.exit != null) {
        return null;
    }

    return .{ .key = pane.key(), .location = pane.location };
}

fn findFirstOpenPane(context: *anyopaque, location: schema.TabLocation) ?pane_mod.PaneLaunched {
    const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
    const pane = client.server.model.panes.firstAt(location) orelse return null;
    return .{ .key = pane.key(), .location = pane.location };
}

fn prepareOpenPaneLaunch(context: *anyopaque, request: open_pane_commands.PrepareLaunch) ![]const u8 {
    const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
    return entrypoint_common.resolveLaunchCwd(
        &client.session.attachments,
        request.launch,
        .any,
    ) catch error.InvalidLaunchCwd;
}

fn launchOpenPane(context: *anyopaque, request: open_pane_commands.LaunchPane) !pane_mod.PaneLaunched {
    const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
    const pane = try client.server.launchPane(
        request.location,
        request.size,
        request.launch,
        request.launch_cwd,
        request.workspace_path,
    );

    return .{ .key = pane.key(), .location = pane.location };
}

fn prepareOpenPaneView(context: *anyopaque, request: open_pane_commands.PrepareView) !void {
    const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
    const pane = client.server.model.panes.resolve(request.pane.key) orelse return error.PaneUnavailable;
    const resize_result = if (pane.ingest_pending)
        pane.requestResize(request.size)
    else
        pane.resize(request.size);
    resize_result catch return error.PaneResizeFailed;

    try schedulePaneObservation(client.server.select, pane);
    try schedulePaneMedia(client.server.select, pane);
}

fn attachOpenPane(context: *anyopaque, launched: pane_mod.PaneLaunched) !void {
    const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
    const pane = client.server.model.panes.resolve(launched.key) orelse return error.PaneUnavailable;
    const attachment = try client.session.attachments.attach(client.server.gpa, pane);
    _ = try attachment.resizeIfNeeded();
}

fn publishOpenPaneEvent(context: *anyopaque, event: open_pane_commands.RuntimeEvent) void {
    const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
    const workspace = switch (event) {
        .workspace_created => |created| created.location.workspace,
        .pane_launched => |launched| launched.location.workspace,
    };
    client.server.notifyWorkspaceChanged(client.session.key, workspace);
}

fn prepareCreateTabLaunch(context: *anyopaque, request: create_tab_commands.PrepareLaunch) ![]const u8 {
    const client: *ClientLaunchContext = @ptrCast(@alignCast(context));

    if (!client.server.holdsGeometry(client.session.key, request.workspace)) {
        return error.GeometryUnavailable;
    }

    return entrypoint_common.resolveLaunchCwd(
        &client.session.attachments,
        request.launch,
        .{ .workspace = request.workspace },
    ) catch error.InvalidLaunchCwd;
}

fn attachCreatedTab(context: *anyopaque, launched: create_tab_commands.LaunchedPane) !void {
    const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
    const pane = client.server.model.panes.findRunning(launched.id) orelse return error.LaunchedPaneUnavailable;

    _ = try client.session.attachments.attach(client.server.gpa, pane);
}

fn launchCreatedTabPane(context: *anyopaque, request: create_tab_commands.LaunchPane) !create_tab_commands.LaunchedPane {
    const server: *Server = @ptrCast(@alignCast(context));
    const pane = try server.launchPane(
        request.location,
        request.size,
        request.launch,
        request.launch_cwd,
        request.workspace_path,
    );

    return .{ .id = pane.id };
}

fn prepareCreateWorkspaceLaunch(context: *anyopaque, request: create_workspace_commands.PrepareLaunch) ![]const u8 {
    const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
    return entrypoint_common.resolveLaunchCwd(
        &client.session.attachments,
        request.launch,
        .any,
    ) catch error.InvalidLaunchCwd;
}

fn acquireCreatedWorkspaceGeometry(context: *anyopaque, workspace: schema.WorkspaceLocation) bool {
    const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
    return client.server.holdsGeometry(client.session.key, workspace);
}

fn releaseCreatedWorkspaceGeometry(context: *anyopaque, workspace: schema.WorkspaceLocation) void {
    const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
    client.server.releaseGeometryFor(client.session.key, workspace);
}

fn launchCreatedWorkspacePane(context: *anyopaque, request: create_workspace_commands.LaunchPane) !create_workspace_commands.LaunchedPane {
    const server: *Server = @ptrCast(@alignCast(context));
    const pane = try server.launchPane(
        request.location,
        request.size,
        request.launch,
        request.launch_cwd,
        request.workspace_path,
    );

    return .{ .id = pane.id };
}

fn replaceCreatedWorkspaceAttachments(context: *anyopaque, launched: create_workspace_commands.LaunchedPane) !void {
    const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
    const pane = client.server.model.panes.findRunning(launched.id) orelse return error.LaunchedPaneUnavailable;
    const previous_workspace = client.session.attachments.currentWorkspace();

    client.session.attachments.clearAttachments();
    if (previous_workspace) |previous| {
        client.server.releaseGeometryFor(client.session.key, previous);
    }

    const attachment = try client.session.attachments.attach(client.server.gpa, pane);
    _ = try attachment.resizeIfNeeded();
}

fn prepareCreatePaneLaunch(context: *anyopaque, request: create_pane_commands.PrepareLaunch) ![]const u8 {
    const client: *ClientLaunchContext = @ptrCast(@alignCast(context));

    if (!client.server.holdsGeometry(client.session.key, request.location.workspace)) {
        return error.GeometryUnavailable;
    }

    return entrypoint_common.resolveLaunchCwd(
        &client.session.attachments,
        request.launch,
        .{ .tab = request.location },
    ) catch error.InvalidLaunchCwd;
}

fn launchCreatedPane(context: *anyopaque, request: create_pane_commands.LaunchPane) !pane_mod.PaneLaunched {
    const server: *Server = @ptrCast(@alignCast(context));
    const pane = try server.launchPane(
        request.location,
        request.size,
        request.launch,
        request.launch_cwd,
        request.workspace_path,
    );

    return .{ .key = pane.key(), .location = pane.location };
}

fn attachCreatedPane(context: *anyopaque, launched: pane_mod.PaneLaunched) !void {
    const client: *ClientLaunchContext = @ptrCast(@alignCast(context));
    const pane = client.server.model.panes.resolve(launched.key) orelse return error.LaunchedPaneUnavailable;
    _ = try client.session.attachments.attach(client.server.gpa, pane);
}

fn publishTabCreated(context: *anyopaque, event: workspace_mod.TabCreated) void {
    const publication: *WorkspaceEventContext = @ptrCast(@alignCast(context));
    publication.server.notifyWorkspaceChanged(publication.origin, event.location.workspace);
}

fn publishTabRenamed(context: *anyopaque, event: workspace_mod.TabRenamed) void {
    const publication: *WorkspaceEventContext = @ptrCast(@alignCast(context));

    publication.server.model.agents.touch();
    publication.server.notifyWorkspaceChanged(publication.origin, event.location.workspace);
}

fn publishTabMoved(context: *anyopaque, event: workspace_mod.TabMoved) void {
    const publication: *WorkspaceEventContext = @ptrCast(@alignCast(context));
    publication.server.notifyWorkspaceChanged(publication.origin, event.location.workspace);
}

fn publishWorkspaceRenamed(context: *anyopaque, event: workspace_mod.WorkspaceRenamed) void {
    const publication: *WorkspaceEventContext = @ptrCast(@alignCast(context));

    publication.server.model.agents.touch();
    publication.server.notifyWorkspaceChanged(publication.origin, event.location);
}

fn publishWorkspaceCreated(context: *anyopaque, event: workspace_mod.WorkspaceCreated) void {
    const publication: *WorkspaceEventContext = @ptrCast(@alignCast(context));
    publication.server.notifyWorkspaceChanged(publication.origin, event.location.workspace);
}

fn publishPaneLaunched(context: *anyopaque, event: pane_mod.PaneLaunched) void {
    const publication: *WorkspaceEventContext = @ptrCast(@alignCast(context));
    publication.server.notifyWorkspaceChanged(publication.origin, event.location.workspace);
}

fn closeTabPanes(context: *anyopaque, location: schema.TabLocation) void {
    const panes: *PaneStore = @ptrCast(@alignCast(context));
    panes.closeAt(location);
}

fn publishTabRemoved(context: *anyopaque, event: workspace_mod.TabRemoved) void {
    const publication: *WorkspaceEventContext = @ptrCast(@alignCast(context));

    if (event.workspace_removed) {
        publication.server.notifyWorkspaceClosed(
            publication.origin,
            event.location.workspace,
            event.previous_workspace,
        );
    } else {
        publication.server.notifyWorkspaceChanged(publication.origin, event.location.workspace);
    }
}

fn runtimeStopNotifications(server: *Server) runtime_stop_commands.Notifications {
    return .{ .context = server, .publish_fn = publishRuntimeStop };
}

fn publishRuntimeStop(context: *anyopaque, event: shutdown_mod.StopRequested) void {
    const server: *Server = @ptrCast(@alignCast(context));
    std.debug.assert(server.shutdown.isRequested());
    std.debug.assert(std.meta.eql(server.shutdown.initiator.?, event.initiator));

    for (&server.clients.items) |*slot| {
        const session = slot.* orelse continue;

        if (session.active()) {
            session.delivery.requestStop();
        }
    }
}

fn notificationPublisher(server: *Server) show_notification_commands.NotificationPublisher {
    return .{ .context = server, .publish_fn = publishRequestedNotification };
}

fn publishRequestedNotification(context: *anyopaque, notification: schema.Notification) u8 {
    const server: *Server = @ptrCast(@alignCast(context));
    return server.publishNotification(notification);
}

fn notificationDelivery(server: *Server) show_notification_controller.Delivery {
    return .{ .context = server, .pump_all_fn = pumpNotificationClients };
}

fn pumpNotificationClients(context: *anyopaque) void {
    const server: *Server = @ptrCast(@alignCast(context));
    server.pumpAll();
}

fn serveInternal(io: Io, backing_gpa: std.mem.Allocator, endpoint: []const u8, options: ServeOptions) !void {
    var heap = diagnostics.Heap.init(backing_gpa);
    const gpa = heap.allocator();
    try options.graphics.validate();
    attachment_mod.initSharedFreezeNonce(io);
    const history_path = options.history_path;
    const stop = options.stop;
    const ingest_gate = options.ingest_gate;
    var child_environment = try pty.Environment.init(gpa, options.environment, "telar");
    defer child_environment.deinit();
    const proxy = if (options.proxy) |proxy_options|
        try proxy_mod.Proxy.create(io, gpa, .{
            .key_path = proxy_options.key_path,
            .certificate_path = proxy_options.certificate_path,
            .bundle_path = proxy_options.bundle_path,
            .passthrough_hosts = proxy_options.passthrough_hosts,
        })
    else
        null;
    var proxy_owned = proxy != null;
    errdefer if (proxy_owned) if (proxy) |service| service.destroy();
    var proxy_worker = if (proxy) |service|
        try io.concurrent(proxy_mod.Proxy.run, .{service})
    else
        null;
    defer if (proxy) |service| {
        if (proxy_worker) |*worker| worker.cancel(io) catch {};
        service.closeObservations(io);
        service.destroy();
        proxy_owned = false;
    };

    var listener = try transport.local.LocalListener.listen(io, endpoint);
    var telemetry_suffix_buffer: [64]u8 = undefined;
    const telemetry_suffix = std.fmt.bufPrint(
        &telemetry_suffix_buffer,
        "runtime-{d}",
        .{std.c.getpid()},
    ) catch "runtime";
    var telemetry = diagnostics.Sink.init(io, endpoint, telemetry_suffix);
    defer telemetry.deinit(io);

    const clients = try gpa.create(ClientStore);
    clients.* = .{};
    defer gpa.destroy(clients);

    var history_service = try history.Service.init(gpa, history_path);
    var history_worker = try io.concurrent(history.runWorker, .{ io, &history_service });
    var history_owned = true;
    errdefer if (history_owned) {
        history_service.closeQueues(io);
        _ = history_worker.await(io) catch {};
        history_service.deinit(io);
    };

    var select_storage: [16 + 2 * max_clients + 7 * max_panes]RuntimeEvent = undefined;
    var select = Io.Select(RuntimeEvent).init(io, &select_storage);
    try select.concurrent(.accepted, acceptClient, .{ io, &listener });
    if (stop) |queue| try select.concurrent(.stopped, waitForStop, .{ io, queue });
    try select.concurrent(.history_response, history.receiveResponse, .{ io, &history_service });
    if (proxy) |service|
        try select.concurrent(.proxy_event, proxy_mod.Proxy.receive, .{ service, io });
    try select.concurrent(.agent_tick, waitForAgentTick, .{io});
    try select.concurrent(.metrics_tick, waitForMetricsTick, .{io});
    if (comptime diagnostics.enabled) {
        if (telemetry.available())
            try select.concurrent(.telemetry_tick, diagnostics.waitForTick, .{io});
    }

    var server: Server = .{
        .io = io,
        .gpa = gpa,
        .heap = &heap,
        .select = &select,
        .history_service = &history_service,
        .child_environment = &child_environment,
        .inherited_environment = options.environment,
        .proxy = proxy,
        .agent_description_options = options.agent_descriptions,
        .launch_fault = options.launch_fault,
        .clients = clients,
        .model = .{
            .panes = .{
                .graphics_limits = options.graphics,
                .graphics_budget = .init(options.graphics.global_bytes),
            },
        },
        .metrics = .{ .started_ns = diagnostics.now(io) },
    };
    var telemetry_buffer: [12288]u8 = undefined;
    var telemetry_write_pending = false;
    defer {
        listener.shutdown();
        for (&server.clients.items) |*slot|
            if (slot.*) |session| session.connection.shutdown(io);
        if (server.handshake_slot) |*pending| pending.shutdown(io);
        // `pane_exit` blocks in libc's waitpid and cannot observe Select
        // cancellation. End the PTY sessions first so their waits can finish;
        // masters stay open here and close in `destroy`, after every actor
        // has been joined, because Darwin's close waits behind blocked writes.
        server.model.panes.shutdown();
        select.cancelDiscard();
        if (proxy_worker) |*worker| {
            worker.cancel(io) catch {};
            proxy_worker = null;
        }
        listener.deinit(io);
        if (server.handshake_slot) |*pending| pending.deinit(io);
        for (&server.clients.items) |*slot| if (slot.*) |session| {
            session.read_pending = false;
            session.send_pending = false;
        };
        server.clients.deinit(io, gpa);
        server.model.panes.deinit();
        var workspace_repository = server.workspaceRepository();
        workspace_repository.deinit();
        history_service.closeQueues(io);
        _ = history_worker.await(io) catch {};
        history_service.deinit(io);
        history_owned = false;
    }

    while (true) {
        const event = try select.await();
        const path = diagnostics.enter(runtimeEventPath(event));
        defer path.restore();
        switch (event) {
            .stopped => |result| return result,
            .accepted => |result| try server.handleAcceptedEvent(result, &listener),
            .handshaken => |result| server.handleHandshakenEvent(result),
            .client_message => |event_value| if (try server.handleClientMessageEvent(event_value)) return,
            .client_sent => |event_value| if (server.handleClientSentEvent(event_value)) return,
            .history_response => |result| try server.handleHistoryResponseEvent(result),
            .proxy_event => |result| try server.handleProxyEvent(result),
            .agent_tick => |result| try server.handleAgentTickEvent(result),
            .agent_description => |result| server.handleAgentDescriptionEvent(result),
            .metrics_tick => |result| try server.handleMetricsTickEvent(result),
            .pane_input_written => |event_value| try server.handlePaneInputWrittenEvent(event_value),
            .pane_response_written => |event_value| try server.handlePaneResponseWrittenEvent(event_value),
            .pane_output => |event_value| try server.handlePaneOutputEvent(event_value, ingest_gate),
            .pane_ingested => |event_value| try server.handlePaneIngestedEvent(event_value),
            .pane_observed => |event_value| try server.handlePaneObservedEvent(event_value),
            .pane_media => |event_value| try server.handlePaneMediaEvent(event_value),
            .pane_exit => |event_value| try server.handlePaneExitEvent(event_value),
            .telemetry_tick => |result| server.handleTelemetryTickEvent(
                result,
                &telemetry,
                &telemetry_buffer,
                &telemetry_write_pending,
            ),
            .telemetry_written => |result| server.handleTelemetryWrittenEvent(
                result,
                &telemetry,
                &telemetry_write_pending,
            ),
        }
    }
}

fn runtimeEventPath(event: RuntimeEvent) diagnostics.Path {
    return switch (event) {
        .pane_output,
        .pane_ingested,
        .pane_input_written,
        .pane_response_written,
        .client_message,
        .client_sent,
        => .interactive,
        .pane_media => .media,
        .pane_observed,
        .history_response,
        .proxy_event,
        .agent_tick,
        .agent_description,
        .metrics_tick,
        .telemetry_tick,
        .telemetry_written,
        => .observation,
        .accepted,
        .handshaken,
        .pane_exit,
        .stopped,
        => .other,
    };
}

fn queueFailure(
    responses: *ResponseQueue,
    request_id: schema.RequestId,
    code: schema.FailureCode,
    message: []const u8,
) !void {
    try responses.push(.{ .request_failed = .{
        .request_id = request_id,
        .code = code,
        .message = message,
    } });
}

fn startSessionSend(
    io: Io,
    select: *Io.Select(RuntimeEvent),
    session: *ClientSession,
    payload: []const u8,
) !void {
    std.debug.assert(!session.send_pending);
    session.send_pending = true;
    select.concurrent(.client_sent, sendSession, .{
        io,
        session.key,
        &session.connection,
        payload,
    }) catch |err| {
        session.send_pending = false;
        return err;
    };
}

fn sendSession(
    io: Io,
    key: ClientKey,
    connection: *core.transport.SocketChannel,
    payload: []const u8,
) ClientSentEvent {
    return .{ .client = key, .result = connection.send(io, payload) };
}

fn writeDiagnostics(
    io: Io,
    sink: *diagnostics.Sink,
    bytes: []const u8,
) anyerror!void {
    try sink.write(io, bytes);
}

const pane_input_runtime_port: pane_input_pump.RuntimePort(Server) = .{
    .start = startPaneInputWrite,
    .collect = collectAfterPaneWrite,
};

const RuntimePaneInputPump = pane_input_pump.Pump(Server, pane_input_runtime_port);

fn paneInputPump(server: *Server) RuntimePaneInputPump {
    return RuntimePaneInputPump.init(server, .{
        .io = server.io,
        .panes = &server.model.panes,
        .metrics = &server.metrics,
    });
}

fn startPaneInputWrite(server: *Server, write: pane_input_pump.Write) !void {
    try server.select.concurrent(.pane_input_written, writePaneInput, .{write});
}

fn collectAfterPaneWrite(server: *Server) void {
    server.collect();
}

fn writePaneInput(write: pane_input_pump.Write) PaneInputEvent {
    const path = diagnostics.enter(.interactive);
    defer path.restore();

    write.pane.pty_write_mutex.lockUncancelable(write.io);
    defer write.pane.pty_write_mutex.unlock(write.io);

    return .{
        .pane = write.pane.key(),
        .started_ns = write.started_ns,
        .result = write.pane.session.file().writeStreamingAll(write.io, write.bytes),
    };
}

const pane_response_runtime_port: pane_response_pump.RuntimePort(Server) = .{
    .start = startPaneResponseWrite,
    .collect = collectAfterPaneWrite,
};

const RuntimePaneResponsePump = pane_response_pump.Pump(Server, pane_response_runtime_port);

fn paneResponsePump(server: *Server) RuntimePaneResponsePump {
    return RuntimePaneResponsePump.init(server, .{
        .io = server.io,
        .panes = &server.model.panes,
        .metrics = &server.metrics,
    });
}

fn schedulePaneResponse(server: *Server, pane: *Pane) !void {
    var response_pump = paneResponsePump(server);
    return response_pump.schedule(pane);
}

fn startPaneResponseWrite(server: *Server, write: pane_response_pump.Write) !void {
    try server.select.concurrent(.pane_response_written, writePaneResponse, .{write});
}

fn writePaneResponse(write: pane_response_pump.Write) PaneResponseEvent {
    const path = diagnostics.enter(.interactive);
    defer path.restore();

    write.pane.pty_write_mutex.lockUncancelable(write.io);
    defer write.pane.pty_write_mutex.unlock(write.io);

    return .{
        .pane = write.pane.key(),
        .result = write.pane.session.file().writeStreamingAll(write.io, write.bytes),
    };
}

fn waitForStop(io: Io, stop: *Io.Queue(u8)) anyerror!void {
    _ = try stop.getOne(io);
}

fn waitForAgentTick(io: Io) anyerror!void {
    try io.sleep(.fromSeconds(1), .awake);
}

/// Host metrics change slowly; two seconds keeps the cost noise-level while
/// the status bar still feels live.
fn waitForMetricsTick(io: Io) anyerror!void {
    try io.sleep(.fromSeconds(2), .awake);
}

fn acceptClient(io: Io, listener: *transport.local.LocalListener) anyerror!core.transport.SocketChannel {
    return listener.accept(io);
}

fn handshakeClient(io: Io, connection: *core.transport.SocketChannel) anyerror!void {
    const response = try transport.handshake.perform(io, connection);
    if (response == .rejected) return error.IncompatibleProtocol;
}

fn startSessionRead(
    io: Io,
    select: *Io.Select(RuntimeEvent),
    session: *ClientSession,
) !void {
    std.debug.assert(!session.read_pending);
    session.read_pending = true;
    select.concurrent(.client_message, receiveSession, .{
        io,
        session.key,
        &session.connection,
        session.receive_buffer,
    }) catch |err| {
        session.read_pending = false;
        return err;
    };
}

fn receiveSession(
    io: Io,
    key: ClientKey,
    connection: *core.transport.SocketChannel,
    buffer: []u8,
) ClientMessageEvent {
    return .{ .client = key, .result = connection.receive(io, buffer) };
}

const PaneOutputRuntime = struct {
    server: *Server,
    ingest_gate: ?*IngestTestGate,
};

const pane_output_runtime_port: pane_output_pipeline.RuntimePort(PaneOutputRuntime) = .{
    .schedule_observation = scheduleOutputObservation,
    .schedule_media = scheduleOutputMedia,
    .start_ingest = startOutputIngest,
    .has_outstanding_frame = paneHasOutstandingFrame,
    .collect = collectAfterOutput,
    .pump_clients = pumpAfterOutput,
};

const RuntimePaneOutputPipeline = pane_output_pipeline.Pipeline(PaneOutputRuntime, pane_output_runtime_port);

fn paneOutputPipeline(context: *PaneOutputRuntime) RuntimePaneOutputPipeline {
    return RuntimePaneOutputPipeline.init(context, .{
        .io = context.server.io,
        .panes = &context.server.model.panes,
        .metrics = &context.server.metrics,
    });
}

fn scheduleOutputObservation(context: *PaneOutputRuntime, pane: *Pane) !void {
    return schedulePaneObservation(context.server.select, pane);
}

fn scheduleOutputMedia(context: *PaneOutputRuntime, pane: *Pane) !void {
    return schedulePaneMedia(context.server.select, pane);
}

const PaneIngestTask = struct {
    ingest: pane_output_pipeline.Ingest,
    gate: ?*IngestTestGate,
};

fn startOutputIngest(context: *PaneOutputRuntime, ingest: pane_output_pipeline.Ingest) !void {
    try context.server.select.concurrent(.pane_ingested, ingestPane, .{PaneIngestTask{
        .ingest = ingest,
        .gate = context.ingest_gate,
    }});
}

fn paneHasOutstandingFrame(context: *PaneOutputRuntime, pane_id: schema.PaneId) bool {
    for (&context.server.clients.items) |*slot| {
        const client = slot.* orelse continue;
        const attachment = client.attachments.find(pane_id) orelse continue;

        if (attachment.outstandingFrameId() != 0) {
            return true;
        }
    }

    return false;
}

fn collectAfterOutput(context: *PaneOutputRuntime) void {
    context.server.collect();
}

fn pumpAfterOutput(context: *PaneOutputRuntime) void {
    context.server.pumpAll();
}

fn ingestPane(task: PaneIngestTask) PaneIngestEvent {
    const path = diagnostics.enter(.interactive);
    defer path.restore();

    if (task.gate) |gate| {
        gate.wait(task.ingest.io) catch |err| {
            return .{ .pane = task.ingest.pane.key(), .result = err };
        };
    }

    var stats: PaneIngestStats = .{};
    stats.elapsed_ns = task.ingest.pane.ingest(task.ingest.io, task.ingest.bytes) catch |err| {
        return .{ .pane = task.ingest.pane.key(), .result = err };
    };

    return .{ .pane = task.ingest.pane.key(), .result = stats };
}

fn schedulePaneObservation(
    select: *Io.Select(RuntimeEvent),
    pane: *Pane,
) !void {
    if (!pane.history_observer.seal()) return;
    pane.actorStarted();
    select.concurrent(.pane_observed, observePane, .{
        pane,
        pane.size,
        pane.agent_process_cache,
    }) catch |err| {
        pane.actorFinished();
        pane.history_observer.finishSealed();
        return err;
    };
}

fn observePane(
    pane: *Pane,
    current_size: schema.TerminalSize,
    process_cache: agent_process.Cache,
) PaneObservationEvent {
    const path = diagnostics.enter(.observation);
    defer path.restore();
    var stats: history.observer.Stats = .{};
    const process_probe = agent_process.probe(
        pane.session.foregroundProcessGroup(),
        pane.session.pid,
        process_cache,
    );
    pane.processHistoryObservation(current_size, &stats);
    return .{ .pane = pane.key(), .stats = stats, .process_probe = process_probe };
}

fn schedulePaneMedia(
    select: *Io.Select(RuntimeEvent),
    pane: *Pane,
) !void {
    if (!pane.media.seal()) return;
    pane.actorStarted();
    select.concurrent(.pane_media, processPaneMedia, .{ pane, pane.size }) catch |err| {
        pane.actorFinished();
        pane.media.finishSealed();
        return err;
    };
}

fn processPaneMedia(pane: *Pane, current_size: schema.TerminalSize) PaneMediaEvent {
    const path = diagnostics.enter(.media);
    defer path.restore();
    var stats: media_mod.Stats = .{};
    pane.processMedia(current_size, &stats);
    return .{ .pane = pane.key(), .stats = stats };
}

/// A resize that cannot get storage retires the affected pane - its state is
/// still coherent because the resize is transactional, but it can no longer
/// follow the client's geometry - and leaves every other pane running.
fn retirePaneOnFailure(pane: *Pane, result: anyerror!void) anyerror!void {
    result catch |err| {
        _ = pane.requestClose();
        return err;
    };
}

test "client session storage stays off the runtime stack" {
    try std.testing.expect(@sizeOf(ClientStore) < @sizeOf(ClientSession));

    const session = try ClientSession.create(
        std.testing.allocator,
        .{ .id = 1, .generation = 1 },
        .{ .stream = undefined },
    );
    defer {
        session.delivery.deinit(std.testing.allocator);
        std.testing.allocator.free(session.receive_buffer);
        std.testing.allocator.destroy(session);
    }

    try std.testing.expectEqual(@as(u64, 1), session.key.id);
    try std.testing.expectEqual(core.transport.max_frame_size, session.receive_buffer.len);
    try std.testing.expectEqual(core.transport.max_frame_size, session.delivery.send_buffer.len);
}

test "a full response queue drops notifications instead of failing" {
    var queue: ResponseQueue = .{};
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(7) },
        .tab_id = @enumFromInt(3),
    };
    while (queue.len < queue.items.len) try queue.push(.{ .tab_moved = .{
        .request_id = .none,
        .location = location,
        .position = 0,
    } });
    queue.pushOrDrop(.{ .tab_moved = .{
        .request_id = .none,
        .location = location,
        .position = 1,
    } });
    try std.testing.expectEqual(@as(u64, 1), queue.dropped);
    try std.testing.expectEqual(@as(u8, queue.items.len), queue.len);
    try std.testing.expectEqualDeep(
        location.workspace,
        queue.resync_workspace.?,
    );
    try std.testing.expect(queue.resync_previous_workspace == null);
    queue.head = 0;
    queue.len = 0;
}

test "management responses overtake queued observation work" {
    var queue: ResponseQueue = .{};
    const fake_history: *history.model.QueryResult = @ptrFromInt(@alignOf(history.model.QueryResult));
    try queue.push(.{ .history_result = fake_history });
    try queue.push(.{ .tab_moved = .{
        .request_id = @enumFromInt(1),
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(7) },
            .tab_id = @enumFromInt(3),
        },
        .position = 0,
    } });

    const management = queue.peekManagement().?;
    try std.testing.expectEqual(@as(u8, 1), management.offset);
    try std.testing.expect(management.response.* == .tab_moved);
    queue.removeAt(management.offset);
    try std.testing.expect(queue.peek().?.* == .history_result);

    // The fake pointer only tests ordering and must not reach `clear`.
    queue.head = 0;
    queue.len = 0;
}

test "a workspace snapshot for a vanished workspace degrades to a failure reply" {
    var workspaces: WorkspaceState = .{};
    var panes: PaneStore = .{};
    var response: PendingResponse = .{ .workspace_snapshot = .{
        .request_id = @enumFromInt(9),
        .workspace = .{ .workspace = try schema.id.workspace(77) },
    } };
    var buffer: [1024]u8 = undefined;
    var history_result: ?*history.model.QueryResult = null;
    const payload = try encodeResponse(.{
        .buffer = &buffer,
        .panes = &panes,
        .workspaces = workspace_mod.Reader.init(&workspaces),
        .history_result = &history_result,
    }, &response);
    const decoded = try schema.decodeServer(payload);
    try std.testing.expect(decoded == .request_failed);
    try std.testing.expectEqual(
        schema.FailureCode.workspace_not_found,
        decoded.request_failed.code,
    );
}

test "runtime VT answers KGP queries and decodes terminal-browser zlib RGBA" {
    const previous_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = previous_log_level;

    const Capture = struct {
        var bytes: [512]u8 = undefined;
        var len: usize = 0;

        fn reset() void {
            len = 0;
        }

        fn writePty(_: *vt.TerminalStream.Handler, response: [:0]const u8) void {
            if (len + response.len > bytes.len) @panic("KGP test response overflow");
            @memcpy(bytes[len..][0..response.len], response);
            len += response.len;
        }
    };

    var terminal = try vt.Terminal.init(std.testing.io, std.testing.allocator, .{
        .cols = 10,
        .rows = 5,
        .kitty_image_storage_limit = core.graphics.max_image_bytes_per_screen,
        .kitty_image_loading_limits = .direct,
    });
    defer terminal.deinit(std.testing.allocator);
    var handler = terminal.vtHandler();
    handler.apc_handler.max_bytes.put(.kitty, core.graphics.max_encoded_chunk_bytes);
    handler.effects.write_pty = Capture.writePty;
    var stream = vt.TerminalStream.init(.{
        .allocator = std.testing.allocator,
        .handler = handler,
    });
    defer stream.deinit();

    Capture.reset();
    stream.nextSlice("\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\");
    try std.testing.expectEqualStrings("\x1b_Gi=31;OK\x1b\\", Capture.bytes[0..Capture.len]);
    try std.testing.expectEqual(@as(usize, 0), terminal.screens.active.kitty_images.images.count());

    // Same encoding shape as terminal-browser: direct RGBA, zlib level 1,
    // independently base64-encoded chunks.
    Capture.reset();
    stream.nextSlice("\x1b_Ga=t,f=32,o=z,s=1,v=1,t=d,i=7,m=1;eAFjZGL+\x1b\\");
    stream.nextSlice("\x1b_Gm=0;DwABEwEG\x1b\\");
    const image = terminal.screens.active.kitty_images.imageById(7).?;
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255 }, image.data.bytes().?);

    Capture.reset();
    stream.nextSlice("\x1b_Ga=q,f=32,o=z,s=1,v=1,t=d,i=8;eAFjZGIGAAANAAc=\x1b\\");
    try std.testing.expect(std.mem.indexOf(
        u8,
        Capture.bytes[0..Capture.len],
        "EINVAL: invalid data",
    ) != null);
    try std.testing.expect(terminal.screens.active.kitty_images.imageById(8) == null);

    Capture.reset();
    stream.nextSlice("\x1b_Ga=q,f=24,s=1,v=1,t=f,i=9;L3RtcC9pbWFnZQ==\x1b\\");
    try std.testing.expect(std.mem.indexOf(
        u8,
        Capture.bytes[0..Capture.len],
        "EINVAL: unsupported medium",
    ) != null);
}

test "agent sounds require exact working transitions" {
    try std.testing.expectEqual(
        schema.AgentSound.ready,
        agentSoundForTransition(.working, .ready).?,
    );
    try std.testing.expectEqual(
        schema.AgentSound.needs_input,
        agentSoundForTransition(.working, .blocked).?,
    );
    try std.testing.expect(agentSoundForTransition(null, .ready) == null);
    try std.testing.expect(agentSoundForTransition(.ready, .ready) == null);
    try std.testing.expect(agentSoundForTransition(.blocked, .ready) == null);
    try std.testing.expect(agentSoundForTransition(.working, .failed) == null);
}

test {
    _ = close_tab_commands;
    _ = close_tab_controller;
    _ = close_pane_commands;
    _ = close_pane_controller;
    _ = copy_selection_commands;
    _ = copy_selection_controller;
    _ = client_request_router;
    _ = create_tab_commands;
    _ = create_tab_controller;
    _ = create_pane_commands;
    _ = create_pane_controller;
    _ = create_workspace_commands;
    _ = create_workspace_controller;
    _ = detach_pane_commands;
    _ = detach_pane_controller;
    _ = frame_ack_commands;
    _ = frame_ack_controller;
    _ = graphics_configuration_commands;
    _ = graphics_configuration_controller;
    _ = graphics_credit_commands;
    _ = graphics_credit_controller;
    _ = history_query;
    _ = history_query_controller;
    _ = move_tab_commands;
    _ = move_tab_controller;
    _ = open_pane_commands;
    _ = open_pane_controller;
    _ = pane_input_commands;
    _ = pane_input_controller;
    _ = pane_input_pump;
    _ = pane_output_pipeline;
    _ = pane_response_pump;
    _ = pane_resize_commands;
    _ = pane_resize_controller;
    _ = pane_viewport_commands;
    _ = pane_viewport_controller;
    _ = request_graphics_snapshot_commands;
    _ = request_graphics_snapshot_controller;
    _ = request_snapshot_commands;
    _ = request_snapshot_controller;
    _ = runtime_stop_commands;
    _ = runtime_stop_controller;
    _ = runtime_state_controller;
    _ = rename_workspace_commands;
    _ = rename_workspace_controller;
    _ = show_notification_commands;
    _ = show_notification_controller;
    _ = tab_snapshot_query;
    _ = tab_snapshot_controller;
    _ = workspace_snapshot_query;
    _ = workspace_snapshot_controller;
    _ = tab_commands;
    _ = tab_controller;
    _ = @import("close_tab_test.zig");
    _ = @import("close_pane_test.zig");
    _ = @import("copy_selection_test.zig");
    _ = @import("create_tab_test.zig");
    _ = @import("create_pane_test.zig");
    _ = @import("create_workspace_test.zig");
    _ = @import("detach_pane_test.zig");
    _ = @import("frame_ack_test.zig");
    _ = @import("graphics_configuration_test.zig");
    _ = @import("graphics_credit_test.zig");
    _ = @import("history_query_test.zig");
    _ = @import("move_tab_test.zig");
    _ = @import("open_pane_test.zig");
    _ = @import("pane_input_test.zig");
    _ = @import("pane_resize_test.zig");
    _ = @import("pane_viewport_test.zig");
    _ = @import("request_graphics_snapshot_test.zig");
    _ = @import("request_snapshot_test.zig");
    _ = @import("runtime_stop_test.zig");
    _ = @import("runtime_state_test.zig");
    _ = @import("rename_tab_test.zig");
    _ = @import("rename_workspace_test.zig");
    _ = @import("show_notification_test.zig");
    _ = @import("tab_snapshot_test.zig");
    _ = @import("workspace_snapshot_test.zig");
    _ = model_mod;
    _ = pane_mod;
    _ = workspace_mod;
    _ = attachment_mod;
    _ = shutdown_mod;
    _ = telemetry_mod;
}
