//! Long-lived runtime for Telar's current schema.

const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");
const agent_mod = @import("../agent/root.zig");
const agent_description_coordinator = @import("agent_description_coordinator.zig");
const agent_maintenance_coordinator = @import("agent_maintenance_coordinator.zig");
const agent_process = @import("../process/root.zig");
const history = @import("../history/root.zig");
const history_runtime_mod = @import("history_runtime.zig");
const attachment_mod = @import("attachment.zig");
const client_admission = @import("client_admission.zig");
const client_request_router = @import("client_request_router.zig");
const client_send_coordinator = @import("client_send_coordinator.zig");
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
const history_response_controller = @import("history_response_controller.zig");
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
const media_projection = @import("media_projection.zig");
const tab_commands = @import("commands/tab.zig");
const tab_controller = @import("controllers/tab.zig");
const pane_launcher_mod = @import("pane_launcher.zig");
const pane_exit_coordinator = @import("pane_exit_coordinator.zig");
const pane_ingest_coordinator = @import("pane_ingest_coordinator.zig");
const pane_media_coordinator = @import("pane_media_coordinator.zig");
const pane_observation_coordinator = @import("pane_observation_coordinator.zig");
const pane_output_pipeline = @import("pane_output_pipeline.zig");
const pane_mod = @import("../pane/root.zig");
const blit = pane_mod.blit;
const media_mod = @import("../media/root.zig");
const model_mod = @import("model/root.zig");
const pty = @import("../pty/root.zig");
const response_queue = @import("response_queue.zig");
const shutdown_mod = @import("shutdown.zig");
const proxy_mod = @import("../proxy/root.zig");
const proxy_observation_adapter = @import("proxy_observation_adapter.zig");
const proxy_runtime_mod = @import("proxy_runtime.zig");
const runtime_encoder = @import("encoder.zig");
pub const system_metrics = @import("system_metrics.zig");
const system_metrics_mod = system_metrics;
const system_metrics_coordinator = @import("system_metrics_coordinator.zig");
const telemetry_mod = @import("telemetry.zig");
const telemetry_tick_coordinator = @import("telemetry_tick_coordinator.zig");
const transport = @import("../transport/root.zig");
const workspace_mod = @import("../workspace/root.zig");

const Io = std.Io;
const File = Io.File;
const schema = core.schema;
const diagnostics = core.diagnostics;

pub const GraphicsLimits = pane_mod.GraphicsLimits;
const Pane = pane_mod.Pane;
const PaneKey = pane_mod.PaneKey;
const PaneStore = pane_mod.PaneStore;
const PaneLauncher = pane_launcher_mod.PaneLauncher;
const max_panes = pane_mod.max_panes;
const WorkspaceRepository = workspace_mod.Repository;
const WorkspaceState = workspace_mod.State;
const max_workspaces = workspace_mod.max_workspaces;
const RuntimeModel = model_mod.RuntimeModel;
const AttachmentStore = attachment_mod.AttachmentStore;
const ClientAdmissionState = client_admission.State(core.transport.SocketChannel);
const Delivery = delivery_mod.Delivery;
const enforceGraphicsQuotas = attachment_mod.enforceGraphicsQuotas;
const RuntimeMetrics = telemetry_mod.RuntimeMetrics;
const TelemetryState = telemetry_mod.State;
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

pub const ServeOptions = struct {
    endpoint: []const u8,
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

pub const ProxyOptions = proxy_runtime_mod.Config;

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
const PaneIngestEvent = pane_ingest_coordinator.Completion;

const PaneObservationEvent = pane_observation_coordinator.Completion;

const PaneMediaEvent = pane_media_coordinator.Completion;

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

    fn hasCapacity(store: *const ClientStore) bool {
        return store.count < store.items.len;
    }

    fn add(store: *ClientStore, gpa: std.mem.Allocator, connection: core.transport.SocketChannel) !*ClientSession {
        if (!store.hasCapacity()) {
            return error.ClientLimitReached;
        }

        if (store.next_id == 0 or store.next_id == std.math.maxInt(u64) or
            store.next_generation == 0 or store.next_generation == std.math.maxInt(u64))
        {
            return error.ClientIdentityExhausted;
        }

        const key: ClientKey = .{
            .id = store.next_id,
            .generation = store.next_generation,
        };

        for (&store.items) |*slot| {
            if (slot.* != null) {
                continue;
            }

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

/// Runs one runtime instance until a stop event or fatal runtime error.
/// `options` is borrowed for the duration of the call.
///
/// ```zig
/// try serve(io, gpa, .{
///     .endpoint = "/tmp/telar.sock",
///     .environment = environment,
/// });
/// ```
pub fn serve(io: Io, gpa: std.mem.Allocator, options: ServeOptions) !void {
    var runtime: Runtime = undefined;
    try runtime.init(.{ .io = io, .backing_gpa = gpa, .options = options });
    defer runtime.deinit();

    try runtime.run();
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
    proxy_runtime: *proxy_runtime_mod.Runtime,
    agent_description_options: ?AgentDescriptionOptions,
    agent_description_state: agent_description_coordinator.State = .{},
    launch_fault: ?*LaunchTestFault,
    clients: *ClientStore,
    client_admission: ClientAdmissionState = .{},
    shutdown: shutdown_mod.State = .{},
    geometry_leases: [max_workspaces]?GeometryLease = @splat(null),
    model: RuntimeModel,
    system_metrics: system_metrics_mod.Sampler = .{},
    metrics: RuntimeMetrics,

    fn collect(server: *Server) void {
        server.collectFinished();
    }

    fn revokePaneCredential(server: *Server, pane: *Pane) void {
        if (server.proxy_runtime.capability()) |proxy| {
            proxy.revokePane(pane.key());
        }
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
            .proxy = server.proxy_runtime.capability(),
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

    fn handleAgentDescriptionEvent(server: *Server, result: agent_mod.description.Result) void {
        var coordinator = agentDescriptionCoordinator(server);
        coordinator.handle(result);
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
                .proxy_active = server.proxy_runtime.active(),
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

    fn handlePaneIngestedEvent(server: *Server, event: PaneIngestEvent) !void {
        var coordinator = paneIngestCoordinator(server);
        return coordinator.handle(event);
    }

    fn handleAcceptedEvent(server: *Server, result: anyerror!core.transport.SocketChannel, listener: *transport.local.LocalListener) !void {
        var runtime: ClientAdmissionRuntime = .{ .server = server, .listener = listener };
        var coordinator = acceptedClientCoordinator(&runtime);
        return coordinator.handle(result);
    }

    fn handleHandshakenEvent(server: *Server, result: anyerror!void) void {
        var coordinator = handshakenClientCoordinator(server);
        coordinator.handle(result);
    }

    fn handleClientSentEvent(server: *Server, event: ClientSentEvent) bool {
        var coordinator = clientSendCoordinator(server);
        return coordinator.handle(.{ .client = event.client, .result = event.result });
    }

    fn handleHistoryResponseEvent(server: *Server, response_result: anyerror!history.Response) !void {
        var controller = historyResponseController(server);
        return controller.handle(response_result);
    }

    fn handleProxyEvent(server: *Server, event_result: anyerror!proxy_mod.Observation) !void {
        var adapter = proxyObservationAdapter(server);
        return adapter.handle(event_result);
    }

    fn handleAgentTickEvent(server: *Server, result: anyerror!void) !void {
        var coordinator = agentMaintenanceCoordinator(server);
        return coordinator.handle(result);
    }

    fn handleMetricsTickEvent(server: *Server, result: anyerror!void) !void {
        var coordinator = systemMetricsCoordinator(server);
        return coordinator.handle(result);
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
        var coordinator = paneObservationCoordinator(server);
        return coordinator.handle(event);
    }

    fn handlePaneMediaEvent(server: *Server, event: PaneMediaEvent) !void {
        var coordinator = paneMediaCoordinator(server);
        return coordinator.handle(event);
    }

    fn handlePaneExitEvent(server: *Server, event: PaneExitEvent) !void {
        var coordinator = paneExitCoordinator(server);
        return coordinator.handle(event);
    }

    fn handleTelemetryTickEvent(server: *Server, result: anyerror!void, state: *TelemetryState) void {
        var coordinator = telemetryTickCoordinator(server, state);
        coordinator.handle(result);
    }

    fn handleTelemetryWrittenEvent(server: *Server, result: anyerror!void, state: *TelemetryState) void {
        switch (state.finishWrite(result)) {
            .ready => {},
            .disable_sink => state.deinit(server.io),
        }
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
    return schedulePaneObservation(server, pane);
}

fn entrypointScheduleMedia(context: *anyopaque, pane: *Pane) !void {
    const server: *Server = @ptrCast(@alignCast(context));
    return schedulePaneMedia(server, pane);
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

    try schedulePaneObservation(client.server, pane);
    try schedulePaneMedia(client.server, pane);
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

const RuntimeStartupPhase = enum {
    child_environment,
    proxy,
    listener,
    telemetry,
    clients,
    history,
    actors,
};

const RuntimeStartup = struct {
    io: Io,
    backing_gpa: std.mem.Allocator,
    options: ServeOptions,
    fail_after: ?RuntimeStartupPhase = null,

    fn checkpoint(startup: RuntimeStartup, phase: RuntimeStartupPhase) !void {
        if (startup.fail_after == phase) {
            return error.InjectedStartupFailure;
        }
    }
};

const Runtime = struct {
    io: Io,
    gpa: std.mem.Allocator,
    heap: diagnostics.Heap,
    child_environment: pty.Environment,
    proxy_runtime: proxy_runtime_mod.Runtime,
    listener: transport.local.LocalListener,
    telemetry: TelemetryState,
    clients: *ClientStore,
    history_runtime: history_runtime_mod.Runtime,
    select_storage: [16 + 2 * max_clients + 7 * max_panes]RuntimeEvent,
    select: Io.Select(RuntimeEvent),
    server: Server,
    ingest_gate: ?*IngestTestGate,

    fn init(runtime: *Runtime, startup: RuntimeStartup) !void {
        runtime.io = startup.io;
        runtime.heap = diagnostics.Heap.init(startup.backing_gpa);
        runtime.gpa = runtime.heap.allocator();
        runtime.ingest_gate = startup.options.ingest_gate;

        try startup.options.graphics.validate();
        attachment_mod.initSharedFreezeNonce(runtime.io);

        runtime.child_environment = try pty.Environment.init(runtime.gpa, startup.options.environment, "telar");
        errdefer runtime.child_environment.deinit();
        try startup.checkpoint(.child_environment);

        runtime.proxy_runtime = try proxy_runtime_mod.Runtime.init(runtime.io, runtime.gpa, startup.options.proxy);
        errdefer runtime.proxy_runtime.deinit();
        try startup.checkpoint(.proxy);

        runtime.listener = try transport.local.LocalListener.listen(runtime.io, startup.options.endpoint);
        errdefer runtime.listener.deinit(runtime.io);
        try startup.checkpoint(.listener);

        runtime.telemetry = initRuntimeTelemetry(runtime.io, startup.options.endpoint);
        errdefer runtime.telemetry.deinit(runtime.io);
        try startup.checkpoint(.telemetry);

        runtime.clients = try createClientStore(runtime.gpa);
        errdefer runtime.gpa.destroy(runtime.clients);
        try startup.checkpoint(.clients);

        runtime.history_runtime = try history_runtime_mod.Runtime.init(runtime.io, runtime.gpa, startup.options.history_path);
        errdefer runtime.history_runtime.deinit();
        try startup.checkpoint(.history);

        runtime.select = Io.Select(RuntimeEvent).init(runtime.io, &runtime.select_storage);
        errdefer runtime.select.cancelDiscard();
        try runtime.scheduleInitialEvents(startup.options.stop);
        try startup.checkpoint(.actors);

        runtime.server = runtime.composeServer(startup.options);
    }

    fn scheduleInitialEvents(runtime: *Runtime, stop: ?*Io.Queue(u8)) !void {
        try runtime.select.concurrent(.accepted, acceptClient, .{ runtime.io, &runtime.listener });
        if (stop) |queue| {
            try runtime.select.concurrent(.stopped, waitForStop, .{ runtime.io, queue });
        }
        try runtime.select.concurrent(.history_response, history.receiveResponse, .{ runtime.io, runtime.history_runtime.service() });

        var proxy_schedule_context: ProxyScheduleContext = .{ .io = runtime.io, .select = &runtime.select };
        try runtime.proxy_runtime.schedule(proxy_schedule_context.scheduler());
        try runtime.select.concurrent(.agent_tick, waitForAgentTick, .{runtime.io});
        try runtime.select.concurrent(.metrics_tick, waitForMetricsTick, .{runtime.io});

        if (comptime diagnostics.enabled) {
            if (runtime.telemetry.available()) {
                try runtime.select.concurrent(.telemetry_tick, diagnostics.waitForTick, .{runtime.io});
            }
        }
    }

    fn composeServer(runtime: *Runtime, options: ServeOptions) Server {
        return .{
            .io = runtime.io,
            .gpa = runtime.gpa,
            .heap = &runtime.heap,
            .select = &runtime.select,
            .history_service = runtime.history_runtime.service(),
            .child_environment = &runtime.child_environment,
            .inherited_environment = options.environment,
            .proxy_runtime = &runtime.proxy_runtime,
            .agent_description_options = options.agent_descriptions,
            .launch_fault = options.launch_fault,
            .clients = runtime.clients,
            .model = .{
                .panes = .{
                    .graphics_limits = options.graphics,
                    .graphics_budget = .init(options.graphics.global_bytes),
                },
            },
            .metrics = .{ .started_ns = diagnostics.now(runtime.io) },
        };
    }

    fn run(runtime: *Runtime) !void {
        while (true) {
            const event = try runtime.select.await();
            const path = diagnostics.enter(runtimeEventPath(event));
            defer path.restore();

            switch (event) {
                .stopped => |result| return result,
                .accepted => |result| try runtime.server.handleAcceptedEvent(result, &runtime.listener),
                .handshaken => |result| runtime.server.handleHandshakenEvent(result),
                .client_message => |event_value| if (try runtime.server.handleClientMessageEvent(event_value)) return,
                .client_sent => |event_value| if (runtime.server.handleClientSentEvent(event_value)) return,
                .history_response => |result| try runtime.server.handleHistoryResponseEvent(result),
                .proxy_event => |result| try runtime.server.handleProxyEvent(result),
                .agent_tick => |result| try runtime.server.handleAgentTickEvent(result),
                .agent_description => |result| runtime.server.handleAgentDescriptionEvent(result),
                .metrics_tick => |result| try runtime.server.handleMetricsTickEvent(result),
                .pane_input_written => |event_value| try runtime.server.handlePaneInputWrittenEvent(event_value),
                .pane_response_written => |event_value| try runtime.server.handlePaneResponseWrittenEvent(event_value),
                .pane_output => |event_value| try runtime.server.handlePaneOutputEvent(event_value, runtime.ingest_gate),
                .pane_ingested => |event_value| try runtime.server.handlePaneIngestedEvent(event_value),
                .pane_observed => |event_value| try runtime.server.handlePaneObservedEvent(event_value),
                .pane_media => |event_value| try runtime.server.handlePaneMediaEvent(event_value),
                .pane_exit => |event_value| try runtime.server.handlePaneExitEvent(event_value),
                .telemetry_tick => |result| runtime.server.handleTelemetryTickEvent(result, &runtime.telemetry),
                .telemetry_written => |result| runtime.server.handleTelemetryWrittenEvent(result, &runtime.telemetry),
            }
        }
    }

    fn deinit(runtime: *Runtime) void {
        runtime.listener.shutdown();
        for (&runtime.server.clients.items) |*slot| {
            if (slot.*) |session| {
                session.connection.shutdown(runtime.io);
            }
        }
        if (runtime.server.client_admission.pendingConnection()) |pending| {
            pending.shutdown(runtime.io);
        }

        // `pane_exit` blocks in libc's waitpid and cannot observe Select
        // cancellation. End the PTY sessions first so their waits can finish;
        // masters stay open here and close in `destroy`, after every actor
        // has been joined, because Darwin's close waits behind blocked writes.
        runtime.server.model.panes.shutdown();
        runtime.select.cancelDiscard();
        runtime.proxy_runtime.deinit();
        runtime.listener.deinit(runtime.io);

        if (runtime.server.client_admission.pendingConnection()) |pending| {
            pending.deinit(runtime.io);
        }
        for (&runtime.server.clients.items) |*slot| {
            if (slot.*) |session| {
                session.read_pending = false;
                session.send_pending = false;
            }
        }

        runtime.server.clients.deinit(runtime.io, runtime.gpa);
        runtime.server.model.panes.deinit();
        var workspace_repository = runtime.server.workspaceRepository();
        workspace_repository.deinit();
        runtime.history_runtime.deinit();
        runtime.gpa.destroy(runtime.clients);
        runtime.telemetry.deinit(runtime.io);
        runtime.child_environment.deinit();
    }
};

fn initRuntimeTelemetry(io: Io, endpoint: []const u8) TelemetryState {
    var telemetry_suffix_buffer: [64]u8 = undefined;
    const telemetry_suffix = std.fmt.bufPrint(
        &telemetry_suffix_buffer,
        "runtime-{d}",
        .{std.c.getpid()},
    ) catch "runtime";
    return TelemetryState.init(io, endpoint, telemetry_suffix);
}

fn createClientStore(gpa: std.mem.Allocator) !*ClientStore {
    const clients = try gpa.create(ClientStore);
    clients.* = .{};
    return clients;
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

fn writeDiagnostics(io: Io, state: *TelemetryState, bytes: []const u8) anyerror!void {
    try state.write(io, bytes);
}

const ClientAdmissionRuntime = struct {
    server: *Server,
    listener: *transport.local.LocalListener,
};

const client_accept_runtime_port: client_admission.AcceptPort(ClientAdmissionRuntime, core.transport.SocketChannel) = .{
    .stopping = clientAdmissionStopping,
    .rearm_accept = rearmClientAccept,
    .has_capacity = clientAdmissionHasCapacity,
    .shutdown_connection = shutdownAdmissionConnection,
    .deinit_connection = deinitAdmissionConnection,
    .start_handshake = startClientHandshake,
};

const RuntimeAcceptedClientCoordinator = client_admission.AcceptCoordinator(ClientAdmissionRuntime, core.transport.SocketChannel, client_accept_runtime_port);

fn acceptedClientCoordinator(runtime: *ClientAdmissionRuntime) RuntimeAcceptedClientCoordinator {
    return RuntimeAcceptedClientCoordinator.init(runtime, &runtime.server.client_admission);
}

fn clientAdmissionStopping(runtime: *ClientAdmissionRuntime) bool {
    return runtime.server.shutdown.isRequested();
}

fn rearmClientAccept(runtime: *ClientAdmissionRuntime) !void {
    try runtime.server.select.concurrent(.accepted, acceptClient, .{ runtime.server.io, runtime.listener });
}

fn clientAdmissionHasCapacity(runtime: *ClientAdmissionRuntime) bool {
    return runtime.server.clients.hasCapacity();
}

fn shutdownAdmissionConnection(runtime: *ClientAdmissionRuntime, connection: *core.transport.SocketChannel) void {
    connection.shutdown(runtime.server.io);
}

fn deinitAdmissionConnection(runtime: *ClientAdmissionRuntime, connection: *core.transport.SocketChannel) void {
    connection.deinit(runtime.server.io);
}

fn startClientHandshake(runtime: *ClientAdmissionRuntime, connection: *core.transport.SocketChannel) !void {
    try runtime.server.select.concurrent(.handshaken, handshakeClient, .{ runtime.server.io, connection });
}

const ClientHandshakeTypes = struct {
    pub const Connection = core.transport.SocketChannel;
    pub const Session = *ClientSession;
};

const client_handshake_runtime_port: client_admission.HandshakePort(Server, ClientHandshakeTypes) = .{
    .stopping = clientHandshakeStopping,
    .deinit_connection = deinitNegotiatedConnection,
    .admit = admitNegotiatedClient,
    .start_receive = startNegotiatedClientRead,
    .drop_session = dropAdmittedClient,
};

const RuntimeHandshakenClientCoordinator = client_admission.HandshakeCoordinator(Server, ClientHandshakeTypes, client_handshake_runtime_port);

fn handshakenClientCoordinator(server: *Server) RuntimeHandshakenClientCoordinator {
    return RuntimeHandshakenClientCoordinator.init(server, &server.client_admission);
}

fn clientHandshakeStopping(server: *Server) bool {
    return server.shutdown.isRequested();
}

fn deinitNegotiatedConnection(server: *Server, connection: *core.transport.SocketChannel) void {
    connection.deinit(server.io);
}

fn admitNegotiatedClient(server: *Server, connection: core.transport.SocketChannel) !*ClientSession {
    return server.clients.add(server.gpa, connection);
}

fn startNegotiatedClientRead(server: *Server, session: *ClientSession) !void {
    try startSessionRead(server.io, server.select, session);
}

fn dropAdmittedClient(server: *Server, session: *ClientSession) void {
    server.dropClient(session.key);
}

const ClientSendTypes = struct {
    pub const Client = ClientKey;
    pub const Session = *ClientSession;
    pub const Completion = delivery_mod.Completion;
    pub const Detach = schema.PaneId;
};

const client_send_runtime_port: client_send_coordinator.RuntimePort(Server, ClientSendTypes) = .{
    .resolve = resolveSentClient,
    .record_stale = recordStaleClientSend,
    .release_send = releaseClientSend,
    .is_closing = sentClientIsClosing,
    .finalize = finalizeSentClient,
    .complete_delivery = completeClientDelivery,
    .drop_client = dropSentClient,
    .detach_after_send = detachAfterClientSend,
    .should_close_after_reply = sentClientShouldCloseAfterReply,
    .stopping = clientSendRuntimeStopping,
    .pump_client = pumpSentClient,
    .pump_all = pumpRuntimeClients,
    .shutdown_delivered = clientSendShutdownDelivered,
};

const RuntimeClientSendCoordinator = client_send_coordinator.Coordinator(Server, ClientSendTypes, client_send_runtime_port);

fn clientSendCoordinator(server: *Server) RuntimeClientSendCoordinator {
    return RuntimeClientSendCoordinator.init(server);
}

fn resolveSentClient(server: *Server, client: ClientKey) ?*ClientSession {
    return server.clients.resolve(client);
}

fn recordStaleClientSend(server: *Server) void {
    server.metrics.stale_client_messages += 1;
}

fn releaseClientSend(_: *Server, session: *ClientSession) void {
    session.send_pending = false;
}

fn sentClientIsClosing(_: *Server, session: *ClientSession) bool {
    return session.closing;
}

fn finalizeSentClient(server: *Server, client: ClientKey) void {
    server.finalizeClient(client);
}

fn completeClientDelivery(_: *Server, session: *ClientSession, result: anyerror!void) delivery_mod.Completion {
    return session.delivery.complete(result);
}

fn dropSentClient(server: *Server, client: ClientKey) void {
    server.dropClient(client);
}

fn detachAfterClientSend(server: *Server, session: *ClientSession, pane: schema.PaneId) void {
    _ = session.attachments.detach(pane);
    server.collect();
}

fn sentClientShouldCloseAfterReply(_: *Server, session: *ClientSession) bool {
    return session.delivery.shouldCloseAfterReply();
}

fn clientSendRuntimeStopping(server: *Server) bool {
    return server.shutdown.isRequested();
}

fn pumpSentClient(server: *Server, session: *ClientSession) !void {
    try server.pump(session);
}

fn clientSendShutdownDelivered(server: *Server) bool {
    return server.shutdownDelivered();
}

const history_response_runtime_port: history_response_controller.RuntimePort(Server, *ClientSession) = .{
    .rearm_receive = rearmHistoryResponse,
    .resolve = resolveHistoryResponseClient,
    .set_close_after_reply = setHistoryCloseAfterReply,
    .enqueue_query_result = enqueueHistoryQueryResult,
    .enqueue_failure = enqueueHistoryFailure,
    .dispose_query_result = disposeHistoryQueryResult,
    .pump_clients = pumpRuntimeClients,
};

const RuntimeHistoryResponseController = history_response_controller.Controller(Server, *ClientSession, history_response_runtime_port);

fn historyResponseController(server: *Server) RuntimeHistoryResponseController {
    return RuntimeHistoryResponseController.init(server);
}

fn rearmHistoryResponse(server: *Server) !void {
    try server.select.concurrent(.history_response, history.receiveResponse, .{ server.io, server.history_service });
}

fn resolveHistoryResponseClient(server: *Server, client: ClientKey) ?*ClientSession {
    return server.clients.resolve(client);
}

fn setHistoryCloseAfterReply(_: *Server, session: *ClientSession, enabled: bool) void {
    session.delivery.setCloseAfterReply(enabled);
}

fn enqueueHistoryQueryResult(_: *Server, session: *ClientSession, result: *history.model.QueryResult) bool {
    session.delivery.responses.push(.{ .history_result = result }) catch return false;
    return true;
}

fn enqueueHistoryFailure(_: *Server, session: *ClientSession, failure: history.model.Failure) bool {
    queueFailure(&session.delivery.responses, failure.request_id, .internal, failure.message) catch return false;
    return true;
}

fn disposeHistoryQueryResult(_: *Server, result: *history.model.QueryResult) void {
    result.deinit();
}

const pane_input_runtime_port: pane_input_pump.RuntimePort(Server) = .{
    .start = startPaneInputWrite,
    .collect = collectPaneLifecycle,
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

fn collectPaneLifecycle(server: *Server) void {
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
    .collect = collectPaneLifecycle,
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
    return schedulePaneObservation(context.server, pane);
}

fn scheduleOutputMedia(context: *PaneOutputRuntime, pane: *Pane) !void {
    return schedulePaneMedia(context.server, pane);
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

    var stats: pane_ingest_coordinator.Stats = .{};
    stats.elapsed_ns = task.ingest.pane.ingest(task.ingest.io, task.ingest.bytes) catch |err| {
        return .{ .pane = task.ingest.pane.key(), .result = err };
    };

    return .{ .pane = task.ingest.pane.key(), .result = stats };
}

const pane_ingest_runtime_port: pane_ingest_coordinator.RuntimePort(Server) = .{
    .schedule_observation = scheduleIngestObservation,
    .schedule_media = scheduleIngestMedia,
    .refresh_clients = refreshPaneClients,
    .schedule_response = schedulePaneResponse,
    .start_read = startNextPaneRead,
    .collect = collectPaneLifecycle,
    .pump_clients = pumpRuntimeClients,
};

const RuntimePaneIngestCoordinator = pane_ingest_coordinator.Coordinator(Server, pane_ingest_runtime_port);

fn paneIngestCoordinator(server: *Server) RuntimePaneIngestCoordinator {
    return RuntimePaneIngestCoordinator.init(server, .{
        .io = server.io,
        .panes = &server.model.panes,
        .metrics = &server.metrics,
    });
}

fn scheduleIngestObservation(server: *Server, pane: *Pane) !void {
    return schedulePaneObservation(server, pane);
}

fn scheduleIngestMedia(server: *Server, pane: *Pane) !void {
    return schedulePaneMedia(server, pane);
}

fn refreshPaneClients(server: *Server, pane: *Pane) void {
    for (&server.clients.items) |*slot| {
        const client = slot.* orelse continue;
        const attachment = client.attachments.find(pane.id) orelse continue;

        _ = attachment.resizeIfNeeded() catch {
            _ = server.detachSessionPane(client, pane.id);
        };
    }
}

fn startNextPaneRead(server: *Server, read: pane_ingest_coordinator.Read) !void {
    try server.select.concurrent(.pane_output, pane_launcher_mod.readPane, .{ read.io, read.pane });
}

fn pumpRuntimeClients(server: *Server) void {
    server.pumpAll();
}

const pane_exit_runtime_port: pane_exit_coordinator.RuntimePort(Server) = .{
    .revoke_credential = revokeExitedPaneCredential,
    .schedule_observation = schedulePaneObservation,
    .collect = collectPaneLifecycle,
    .pump_clients = pumpRuntimeClients,
};

const RuntimePaneExitCoordinator = pane_exit_coordinator.Coordinator(Server, pane_exit_runtime_port);

fn paneExitCoordinator(server: *Server) RuntimePaneExitCoordinator {
    return RuntimePaneExitCoordinator.init(server, .{
        .panes = &server.model.panes,
        .agents = &server.model.agents,
        .metrics = &server.metrics,
    });
}

fn revokeExitedPaneCredential(server: *Server, pane: *Pane) void {
    server.revokePaneCredential(pane);
}

const agent_description_runtime_port: agent_description_coordinator.RuntimePort(Server) = .{
    .start = startAgentDescription,
    .persist = persistAgentDescription,
    .pump_clients = pumpRuntimeClients,
};

const RuntimeAgentDescriptionCoordinator = agent_description_coordinator.Coordinator(Server, agent_description_runtime_port);

fn agentDescriptionCoordinator(server: *Server) RuntimeAgentDescriptionCoordinator {
    const command: ?agent_mod.description.Command = if (server.agent_description_options) |options|
        .{ .arguments = options.arguments, .timeout_ms = options.timeout_ms }
    else
        null;

    return RuntimeAgentDescriptionCoordinator.init(server, .{
        .agents = &server.model.agents,
        .state = &server.agent_description_state,
        .command = command,
    });
}

fn startAgentDescription(server: *Server, command: agent_mod.description.Command, job_value: agent_mod.description.Job) !void {
    var job = job_value;
    defer std.crypto.secureZero(u8, &job.query);

    try server.select.concurrent(
        .agent_description,
        agent_mod.description.generate,
        .{ server.io, server.gpa, command, job },
    );
}

fn persistAgentDescription(server: *Server, finished: agent_mod.DescriptionFinished) void {
    _ = server.history_service.setSessionTitle(
        server.io,
        finished.session_id,
        finished.titleSlice(),
        finished.source,
        finished.state,
    );
}

const agent_maintenance_runtime_port: agent_maintenance_coordinator.RuntimePort(Server) = .{
    .rearm_tick = rearmAgentMaintenance,
    .now_ms = runtimeWallClockMs,
    .pump_clients = pumpRuntimeClients,
};

const RuntimeAgentMaintenanceCoordinator = agent_maintenance_coordinator.Coordinator(Server, agent_maintenance_runtime_port);

fn agentMaintenanceCoordinator(server: *Server) RuntimeAgentMaintenanceCoordinator {
    return RuntimeAgentMaintenanceCoordinator.init(server, .{ .agents = &server.model.agents });
}

fn rearmAgentMaintenance(server: *Server) !void {
    try server.select.concurrent(.agent_tick, waitForAgentTick, .{server.io});
}

fn runtimeWallClockMs(server: *Server) i64 {
    return Io.Timestamp.now(server.io, .real).toMilliseconds();
}

const system_metrics_runtime_port: system_metrics_coordinator.RuntimePort(Server) = .{
    .rearm_tick = rearmSystemMetrics,
    .sample = sampleSystemMetrics,
    .pump_clients = pumpRuntimeClients,
};

const RuntimeSystemMetricsCoordinator = system_metrics_coordinator.Coordinator(Server, system_metrics_runtime_port);

fn systemMetricsCoordinator(server: *Server) RuntimeSystemMetricsCoordinator {
    return RuntimeSystemMetricsCoordinator.init(server, .{ .sampler = &server.system_metrics });
}

fn rearmSystemMetrics(server: *Server) !void {
    try server.select.concurrent(.metrics_tick, waitForMetricsTick, .{server.io});
}

fn sampleSystemMetrics(_: *Server, sampler: *system_metrics_mod.Sampler) void {
    sampler.sample();
}

const proxy_observation_runtime_port: proxy_observation_adapter.RuntimePort(Server) = .{
    .rearm_receive = rearmProxyObservation,
    .schedule_description = scheduleAgentDescriptionWork,
    .pump_clients = pumpRuntimeClients,
};

const RuntimeProxyObservationAdapter = proxy_observation_adapter.Adapter(Server, proxy_observation_runtime_port);

fn proxyObservationAdapter(server: *Server) RuntimeProxyObservationAdapter {
    return RuntimeProxyObservationAdapter.init(server, .{
        .panes = &server.model.panes,
        .agents = &server.model.agents,
        .metrics = &server.metrics,
    });
}

const ProxyScheduleContext = struct {
    io: Io,
    select: *Io.Select(RuntimeEvent),

    fn scheduler(context: *ProxyScheduleContext) proxy_runtime_mod.ObservationScheduler {
        return .{ .context = context, .schedule_fn = schedule };
    }

    fn schedule(context_value: *anyopaque, proxy: *proxy_mod.Proxy) !void {
        const context: *ProxyScheduleContext = @ptrCast(@alignCast(context_value));
        try context.select.concurrent(.proxy_event, proxy_mod.Proxy.receive, .{ proxy, context.io });
    }
};

fn rearmProxyObservation(server: *Server) !void {
    var context: ProxyScheduleContext = .{ .io = server.io, .select = server.select };
    try server.proxy_runtime.schedule(context.scheduler());
}

const telemetry_tick_runtime_port: telemetry_tick_coordinator.RuntimePort(Server) = .{
    .available = telemetryAvailable,
    .disable = disableTelemetry,
    .schedule_tick = scheduleTelemetryTick,
    .format_sample = formatTelemetrySample,
    .schedule_write = scheduleTelemetryWrite,
};

const RuntimeTelemetryTickCoordinator = telemetry_tick_coordinator.Coordinator(Server, telemetry_tick_runtime_port);

fn telemetryTickCoordinator(server: *Server, state: *TelemetryState) RuntimeTelemetryTickCoordinator {
    return RuntimeTelemetryTickCoordinator.init(server, state);
}

fn telemetryAvailable(_: *Server, state: *const TelemetryState) bool {
    return state.available();
}

fn disableTelemetry(server: *Server, state: *TelemetryState) void {
    state.deinit(server.io);
}

fn scheduleTelemetryTick(server: *Server) !void {
    try server.select.concurrent(.telemetry_tick, diagnostics.waitForTick, .{server.io});
}

fn formatTelemetrySample(server: *Server, buffer: []u8) ![]const u8 {
    var attachment_stores: [max_clients]*const AttachmentStore = undefined;
    var attachment_count: usize = 0;
    var clients: telemetry_mod.ClientSample = .{ .count = server.clients.count };

    for (&server.clients.items) |*slot| {
        const session = slot.* orelse continue;
        attachment_stores[attachment_count] = &session.attachments;
        attachment_count += 1;
        clients.response_queue_depth += session.delivery.responses.len;
        clients.response_queue_high_water += session.delivery.responses.high_water;
        clients.response_queue_dropped +|= session.delivery.responses.dropped;
    }

    clients.attachment_stores = attachment_stores[0..attachment_count];

    const proxy_metrics = server.proxy_runtime.metrics();
    const workspaces = server.workspaceReader();

    return formatRuntimeTelemetry(buffer, .{
        .io = server.io,
        .metrics = &server.metrics,
        .clients = clients,
        .workspace_count = workspaces.count(),
        .tab_count = workspaces.totalTabs(),
        .panes = &server.model.panes,
        .history_service = server.history_service,
        .proxy = .{
            .active = server.proxy_runtime.active(),
            .active_connections = proxy_metrics.active_connections,
            .event_queue_depth = proxy_metrics.queued_events,
            .event_queue_high_water = proxy_metrics.event_queue_high_water,
            .dropped_events = proxy_metrics.dropped_events,
            .rejected_connections = proxy_metrics.rejected_connections,
            .invalid_authorization_rejections = proxy_metrics.invalid_authorization_rejections,
            .unknown_credential_rejections = proxy_metrics.unknown_credential_rejections,
            .connection_limit_drops = proxy_metrics.connection_limit_drops,
            .h2_decode_failures = proxy_metrics.h2_decode_failures,
            .passthrough_connections = proxy_metrics.passthrough_connections,
            .upstream_connect_failures = proxy_metrics.upstream_connect_failures,
            .tls_context_failures = proxy_metrics.tls_context_failures,
            .tls_upstream_handshake_failures = proxy_metrics.tls_upstream_handshake_failures,
            .tls_downstream_handshake_failures = proxy_metrics.tls_downstream_handshake_failures,
            .tls_mint_failures = proxy_metrics.tls_mint_failures,
        },
        .heap = server.heap,
    });
}

fn scheduleTelemetryWrite(server: *Server, state: *TelemetryState, line: []const u8) !void {
    try server.select.concurrent(.telemetry_written, writeDiagnostics, .{ server.io, state, line });
}

const pane_observation_runtime_port: pane_observation_coordinator.RuntimePort(Server) = .{
    .start = startPaneObservation,
    .publish_sound = publishObservedAgentSound,
    .schedule_description = scheduleAgentDescriptionWork,
    .collect = collectPaneLifecycle,
    .pump_clients = pumpRuntimeClients,
};

const RuntimePaneObservationCoordinator = pane_observation_coordinator.Coordinator(Server, pane_observation_runtime_port);

fn paneObservationCoordinator(server: *Server) RuntimePaneObservationCoordinator {
    return RuntimePaneObservationCoordinator.init(server, .{
        .io = server.io,
        .panes = &server.model.panes,
        .agents = &server.model.agents,
        .metrics = &server.metrics,
    });
}

fn schedulePaneObservation(server: *Server, pane: *Pane) !void {
    var coordinator = paneObservationCoordinator(server);
    return coordinator.schedule(pane);
}

fn startPaneObservation(server: *Server, work: pane_observation_coordinator.Work) !void {
    try server.select.concurrent(.pane_observed, observePane, .{work});
}

fn observePane(work: pane_observation_coordinator.Work) PaneObservationEvent {
    const path = diagnostics.enter(.observation);
    defer path.restore();

    var stats: history.observer.Stats = .{};
    const process_probe = agent_process.probe(
        work.pane.session.foregroundProcessGroup(),
        work.pane.session.pid,
        work.process_cache,
    );
    work.pane.processHistoryObservation(work.current_size, &stats);
    return .{ .pane = work.pane.key(), .stats = stats, .process_probe = process_probe };
}

fn publishObservedAgentSound(server: *Server, notification: schema.AgentSoundNotification) void {
    server.publishAgentSound(notification);
}

fn scheduleAgentDescriptionWork(server: *Server) void {
    var coordinator = agentDescriptionCoordinator(server);
    _ = coordinator.schedule();
}

const pane_media_runtime_port: pane_media_coordinator.RuntimePort(Server) = .{
    .start = startPaneMedia,
    .enforce_quotas = enforcePaneGraphicsQuotas,
    .synchronize_clients = synchronizeMediaClients,
    .schedule_response = schedulePaneResponse,
    .pump_clients = pumpRuntimeClients,
    .collect = collectPaneLifecycle,
};

const RuntimePaneMediaCoordinator = pane_media_coordinator.Coordinator(Server, pane_media_runtime_port);

fn paneMediaCoordinator(server: *Server) RuntimePaneMediaCoordinator {
    return RuntimePaneMediaCoordinator.init(server, .{
        .panes = &server.model.panes,
        .metrics = &server.metrics,
    });
}

fn schedulePaneMedia(server: *Server, pane: *Pane) !void {
    var coordinator = paneMediaCoordinator(server);
    return coordinator.schedule(pane);
}

fn startPaneMedia(server: *Server, work: pane_media_coordinator.Work) !void {
    try server.select.concurrent(.pane_media, processPaneMedia, .{work});
}

fn processPaneMedia(work: pane_media_coordinator.Work) PaneMediaEvent {
    const path = diagnostics.enter(.media);
    defer path.restore();

    var stats: media_mod.Stats = .{};
    work.pane.processMedia(work.current_size, &stats);
    return .{ .pane = work.pane.key(), .stats = stats };
}

fn enforcePaneGraphicsQuotas(server: *Server, pane: *Pane) void {
    enforceGraphicsQuotas(server.io, pane);
}

fn synchronizeMediaClients(server: *Server, pane: *Pane, reset: bool) media_projection.Stats {
    var stores: [max_clients]*AttachmentStore = undefined;
    var count: usize = 0;

    for (&server.clients.items) |*slot| {
        const client = slot.* orelse continue;
        stores[count] = &client.attachments;
        count += 1;
    }

    return media_projection.synchronize(pane, stores[0..count], reset);
}

fn expectRuntimeEndpointRemoved(io: Io, endpoint: []const u8) !void {
    try std.testing.expectError(
        error.FileNotFound,
        Io.Dir.cwd().statFile(io, endpoint, .{ .follow_symlinks = false }),
    );
}

test "invalid graphics limits fail before runtime resources are created" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var endpoint_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "{s}/invalid.sock", .{directory_buffer[0..directory_len]});
    var runtime: Runtime = undefined;

    try std.testing.expectError(error.InvalidGraphicsLimits, runtime.init(.{
        .io = io,
        .backing_gpa = std.testing.allocator,
        .options = .{
            .endpoint = endpoint,
            .environment = std.testing.environ,
            .graphics = .{ .pane_bytes = 1 },
        },
    }));
    try expectRuntimeEndpointRemoved(io, endpoint);
}

test "every runtime startup checkpoint rolls back acquired resources" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);

    for (std.enums.values(RuntimeStartupPhase), 0..) |phase, index| {
        var endpoint_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const endpoint = try std.fmt.bufPrint(
            &endpoint_buffer,
            "{s}/startup-{d}.sock",
            .{ directory_buffer[0..directory_len], index },
        );
        var runtime: Runtime = undefined;

        try std.testing.expectError(error.InjectedStartupFailure, runtime.init(.{
            .io = io,
            .backing_gpa = std.testing.allocator,
            .options = .{ .endpoint = endpoint, .environment = std.testing.environ },
            .fail_after = phase,
        }));
        try expectRuntimeEndpointRemoved(io, endpoint);
    }
}

test "runtime composition keeps every borrowed capability at a stable address" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var endpoint_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "{s}/composed.sock", .{directory_buffer[0..directory_len]});
    var runtime: Runtime = undefined;
    try runtime.init(.{
        .io = io,
        .backing_gpa = std.testing.allocator,
        .options = .{ .endpoint = endpoint, .environment = std.testing.environ },
    });

    try std.testing.expect(runtime.server.heap == &runtime.heap);
    try std.testing.expect(runtime.server.select == &runtime.select);
    try std.testing.expect(runtime.server.history_service == runtime.history_runtime.service());
    try std.testing.expect(runtime.server.child_environment == &runtime.child_environment);
    try std.testing.expect(runtime.server.proxy_runtime == &runtime.proxy_runtime);
    try std.testing.expect(runtime.server.clients == runtime.clients);

    runtime.deinit();
    try expectRuntimeEndpointRemoved(io, endpoint);
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

test {
    _ = agent_description_coordinator;
    _ = agent_maintenance_coordinator;
    _ = client_admission;
    _ = client_send_coordinator;
    _ = system_metrics_coordinator;
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
    _ = history_response_controller;
    _ = history_runtime_mod;
    _ = move_tab_commands;
    _ = move_tab_controller;
    _ = media_projection;
    _ = open_pane_commands;
    _ = open_pane_controller;
    _ = pane_input_commands;
    _ = pane_input_controller;
    _ = pane_input_pump;
    _ = pane_exit_coordinator;
    _ = pane_ingest_coordinator;
    _ = pane_media_coordinator;
    _ = pane_observation_coordinator;
    _ = telemetry_tick_coordinator;
    _ = proxy_observation_adapter;
    _ = proxy_runtime_mod;
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
