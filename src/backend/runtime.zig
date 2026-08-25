//! Long-lived runtime for Telar's current schema.

const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");
const agent_mod = @import("agent.zig");
const blit = @import("blit.zig");
const history = @import("history/root.zig");
const graphics_sync = @import("graphics_sync.zig");
const media_mod = @import("media.zig");
const pane_mod = @import("pane.zig");
const pty = @import("pty.zig");
const response_queue = @import("response_queue.zig");
const proxy_mod = @import("proxy/root.zig");
const runtime_encoder = @import("runtime_encoder.zig");
const system_metrics_mod = @import("system_metrics.zig");
const telemetry_mod = @import("telemetry.zig");
const transport = @import("transport.zig");
const workspace_mod = @import("workspace.zig");

const Io = std.Io;
const File = Io.File;
const schema = core.schema;
const diagnostics = core.diagnostics;

pub const GraphicsLimits = pane_mod.GraphicsLimits;
const Pane = pane_mod.Pane;
const PaneKey = pane_mod.PaneKey;
const PaneIngestStats = pane_mod.PaneIngestStats;
const PaneStore = pane_mod.PaneStore;
const historyClock = pane_mod.historyClock;
const max_panes = pane_mod.max_panes;
const WorkspaceStore = workspace_mod.WorkspaceStore;
const max_workspaces = workspace_mod.max_workspaces;
const Attachment = graphics_sync.Attachment;
const AttachmentStore = graphics_sync.AttachmentStore;
const abandonGraphicsBatch = graphics_sync.abandonGraphicsBatch;
const encodeNextGraphics = graphics_sync.encodeNextGraphics;
const enforceGraphicsQuotas = graphics_sync.enforceGraphicsQuotas;
const RuntimeMetrics = telemetry_mod.RuntimeMetrics;
const formatRuntimeTelemetry = telemetry_mod.formatRuntimeTelemetry;
const max_clients = 8;
const PendingResponse = response_queue.PendingResponse;
const PendingTabCreated = response_queue.PendingTabCreated;
const PendingTabRenamed = response_queue.PendingTabRenamed;
const ResponseQueue = response_queue.ResponseQueue;
const encodeFrame = runtime_encoder.encodeFrame;
const encodeResponse = runtime_encoder.encodeResponse;

pub const ServeOptions = struct {
    graphics: GraphicsLimits = .{},
    environment: std.process.Environ,
    /// SQLite database for durable history; the default keeps it in memory.
    history_path: [:0]const u8 = ":memory:",
    proxy: ?ProxyOptions = null,
    /// Test seam: stops the otherwise long-lived runtime without signals.
    stop: ?*Io.Queue(u8) = null,
    /// Test seam: holds a pane's ingest actor open. See `IngestTestGate`.
    ingest_gate: ?*IngestTestGate = null,
};

pub const ProxyOptions = struct {
    key_path: []const u8,
    certificate_path: []const u8,
    bundle_path: []const u8,
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

const PaneOutputEvent = struct {
    pane: PaneKey,
    result: anyerror!u16,
};

const PaneIngestEvent = struct {
    pane: PaneKey,
    result: anyerror!PaneIngestStats,
};

const PaneObservationEvent = struct {
    pane: PaneKey,
    stats: history.observer.Stats,
};

const PaneMediaEvent = struct {
    pane: PaneKey,
    stats: media_mod.Stats,
};

const PaneInputEvent = struct {
    pane: PaneKey,
    len: usize,
    started_ns: u64,
    result: anyerror!void,
};

const PaneExitEvent = struct {
    pane: PaneKey,
    result: anyerror!pty.Exit,
};

const PaneResponseEvent = struct {
    pane: PaneKey,
    result: anyerror!void,
};

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
    proxy_event: anyerror!proxy_mod.middleware.Event,
    agent_tick: anyerror!void,
    metrics_tick: anyerror!void,
    stopped: anyerror!void,
};

const ClientRole = enum { undecided, ui, control };

const ClientSession = struct {
    key: ClientKey,
    connection: core.transport.SocketChannel,
    receive_buffer: []u8,
    send_buffer: []u8,
    attachments: AttachmentStore = .{},
    responses: ResponseQueue = .{},
    role: ClientRole = .undecided,
    read_pending: bool = false,
    send_pending: bool = false,
    closing: bool = false,
    close_after_send: bool = false,
    stopping_pending: bool = false,
    stopping_in_flight: bool = false,
    sent_exit_pane: ?schema.PaneId = null,
    /// Declared by the client through `configure_graphics` before it opens
    /// panes; attachments created afterwards inherit it.
    shared_graphics: bool = false,
    runtime_state_requested: bool = false,
    proxy_status_sent: bool = false,
    agent_revision_sent: u64 = 0,
    system_metrics_revision_sent: u64 = 0,
    workspace_list_revision_sent: u64 = 0,

    fn create(
        gpa: std.mem.Allocator,
        key: ClientKey,
        connection: core.transport.SocketChannel,
    ) !*ClientSession {
        const receive_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
        errdefer gpa.free(receive_buffer);
        const send_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
        errdefer gpa.free(send_buffer);
        const session = try gpa.create(ClientSession);
        session.* = .{
            .key = key,
            .connection = connection,
            .receive_buffer = receive_buffer,
            .send_buffer = send_buffer,
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
        session.responses.clear();
        gpa.free(session.receive_buffer);
        gpa.free(session.send_buffer);
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

const ShutdownState = struct {
    requested: bool = false,
    initiator: ?ClientKey = null,
};

const GeometryLease = struct {
    workspace: schema.WorkspaceLocation,
    owner: ClientKey,
};

comptime {
    // `OwnedCommand.init` copies a schema-validated launch into `pty.Command`
    // argv slots; the wire bound must never outgrow the PTY array.
    std.debug.assert(schema.max_argument_count <= pty.max_args);
}

const OwnedCommand = struct {
    command: pty.Command,
    arguments: []const [:0]u8,
    cwd: [:0]u8,
    gpa: std.mem.Allocator,

    fn init(
        gpa: std.mem.Allocator,
        launch: schema.LaunchView,
        environment: *const pty.Environment,
    ) !OwnedCommand {
        if (launch.environment_mode != .inherit_runtime or launch.environment_count != 0)
            return error.UnsupportedEnvironment;

        const arguments = try gpa.alloc([:0]u8, launch.argument_count);
        errdefer gpa.free(arguments);
        var initialized: usize = 0;
        errdefer for (arguments[0..initialized]) |argument| gpa.free(argument);

        var iterator = launch.arguments();
        while (try iterator.next()) |argument| {
            arguments[initialized] = try gpa.dupeZ(u8, argument);
            initialized += 1;
        }
        const cwd = try gpa.dupeZ(u8, launch.cwd);
        errdefer gpa.free(cwd);

        var command: pty.Command = .{
            .file = arguments[0].ptr,
            .cwd = cwd.ptr,
            .environment = environment,
        };
        for (arguments, 0..) |argument, index| command.argv[index] = argument.ptr;
        return .{ .command = command, .arguments = arguments, .cwd = cwd, .gpa = gpa };
    }

    fn deinit(command: *OwnedCommand) void {
        for (command.arguments) |argument| command.gpa.free(argument);
        command.gpa.free(command.arguments);
        command.gpa.free(command.cwd);
    }
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

/// Everything one running runtime instance owns: the wire endpoints, the
/// stores, and the send state. Event arms and helpers used to thread a dozen
/// pointers each; they now share this struct.
const Server = struct {
    io: Io,
    gpa: std.mem.Allocator,
    select: *Io.Select(RuntimeEvent),
    history_service: *history.Service,
    child_environment: *const pty.Environment,
    inherited_environment: std.process.Environ,
    proxy_service: ?*proxy_mod.service.Service,
    clients: *ClientStore,
    handshake_slot: ?core.transport.SocketChannel = null,
    handshake_pending: bool = false,
    shutdown: ShutdownState = .{},
    geometry_leases: [max_workspaces]?GeometryLease = @splat(null),
    workspaces: WorkspaceStore,
    panes: PaneStore,
    agents: agent_mod.Store = .{},
    system_metrics: system_metrics_mod.Sampler = .{},
    metrics: RuntimeMetrics,

    fn collect(server: *Server) void {
        server.collectFinished();
    }

    /// Reaps panes whose child exited and which no actor still borrows, then
    /// closes tabs that ran out of panes. Spans three stores, which is why it
    /// lives on the server rather than on any one of them.
    fn collectFinished(server: *Server) void {
        const store = &server.panes;
        if (store.exited_count == 0) return;
        for (&store.items) |*slot| {
            const pane = slot.* orelse continue;
            if (!pane.readyToDestroy()) continue;
            for (&server.clients.items) |*client_slot| {
                const client = client_slot.* orelse continue;
                if (client.attachments.find(pane.id) != null) break;
            } else {
                const location = pane.location;
                store.index.remove(schema.id.raw(pane.id));
                store.exited_count -= 1;
                slot.* = null;
                store.count -= 1;
                _ = server.agents.remove(pane.key());
                if (server.proxy_service) |service| if (pane.proxy_token) |token|
                    service.unregisterCredential(.{
                        .pane_id = pane.id,
                        .pane_generation = pane.generation,
                        .token = token,
                    });
                pane.destroy();
                if (store.hasAt(location) or server.workspaces.findTab(location) == null) continue;

                const workspace_closed = server.workspaces.removeTab(location).?;
                for (&server.clients.items) |*client_slot| {
                    const client = client_slot.* orelse continue;
                    if (!client.active() or !client.attachments.observes(location.workspace)) continue;
                    client.responses.pushOrDrop(.{ .tab_closed = .{
                        .request_id = .none,
                        .location = location,
                        .workspace_closed = workspace_closed,
                    } });
                }
            }
        }
    }

    fn dropClient(server: *Server, key: ClientKey) void {
        const session = server.clients.resolve(key) orelse return;
        if (!session.closing) {
            session.closing = true;
            session.connection.shutdown(server.io);
            session.attachments.deinit();
            session.responses.clear();
            server.releaseGeometry(key);
            server.collect();
        }
        server.finalizeClient(key);
    }

    fn finalizeClient(server: *Server, key: ClientKey) void {
        const session = server.clients.resolve(key) orelse return;
        if (!session.closing or session.read_pending or session.send_pending) return;
        _ = server.clients.remove(server.io, server.gpa, key);
    }

    fn holdsGeometry(
        server: *Server,
        key: ClientKey,
        workspace: schema.WorkspaceLocation,
    ) bool {
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
            if (std.meta.eql(lease.owner, key)) slot.* = null;
        }
    }

    fn releaseGeometryFor(
        server: *Server,
        key: ClientKey,
        workspace: schema.WorkspaceLocation,
    ) void {
        for (&server.geometry_leases) |*slot| {
            const lease = slot.* orelse continue;
            if (std.meta.eql(lease.owner, key) and std.meta.eql(lease.workspace, workspace))
                slot.* = null;
        }
    }

    fn notifyWorkspaceChanged(
        server: *Server,
        origin: ClientKey,
        workspace: schema.WorkspaceLocation,
    ) void {
        for (&server.clients.items) |*slot| {
            const session = slot.* orelse continue;
            if (std.meta.eql(session.key, origin) or !session.active()) continue;
            if (session.attachments.observes(workspace))
                session.responses.resync_workspace = workspace;
        }
    }

    fn pumpAll(server: *Server) void {
        for (&server.clients.items) |*slot| {
            const session = slot.* orelse continue;
            const key = session.key;
            server.pump(session) catch server.dropClient(key);
        }
        for (server.panes.items) |slot| {
            const pane = slot orelse continue;
            server.settlePaneDamage(pane);
        }
    }

    fn settlePaneDamage(server: *Server, pane: *Pane) void {
        if (pane.render_pending) return;
        for (&server.clients.items) |*slot| {
            const session = slot.* orelse continue;
            const attachment = session.attachments.find(pane.id) orelse continue;
            if (attachment.observed_cell_revision != pane.cell_revision) return;
        }
        @memset(pane.damaged_rows, false);
        pane.dirty = false;
    }

    fn requestShutdown(server: *Server, initiator: ClientKey) void {
        if (server.shutdown.requested) return;
        server.shutdown = .{ .requested = true, .initiator = initiator };
        for (&server.clients.items) |*slot| {
            const session = slot.* orelse continue;
            if (session.active()) session.stopping_pending = true;
        }
    }

    fn shutdownDelivered(server: *const Server) bool {
        if (!server.shutdown.requested) return false;
        for (&server.clients.items) |*slot| {
            const session = slot.* orelse continue;
            if (!session.closing and (session.stopping_pending or
                session.stopping_in_flight or session.send_pending)) return false;
        }
        return true;
    }

    fn availableGraphicsCredit(attachments: *const AttachmentStore) usize {
        var outstanding: usize = 0;
        for (attachments.items) |slot| {
            const attachment = slot orelse continue;
            outstanding +|= core.graphics.max_image_bytes_per_pane -
                @min(attachment.graphics_credit, core.graphics.max_image_bytes_per_pane);
        }
        return core.graphics.max_image_bytes_global -|
            @min(outstanding, core.graphics.max_image_bytes_global);
    }

    fn pump(server: *Server, session: *ClientSession) !void {
        const io = server.io;
        const select = server.select;
        const buffer = session.send_buffer;
        const attachments = &session.attachments;
        const panes = &server.panes;
        const workspaces = &server.workspaces;
        const responses = &session.responses;
        const metrics = &server.metrics;
        if (!session.active() or session.send_pending) return;

        if (session.stopping_pending) {
            const payload = try schema.encodeRuntimeStopping(buffer);
            session.stopping_pending = false;
            session.stopping_in_flight = true;
            startSessionSend(io, select, session, payload) catch |err| {
                session.stopping_in_flight = false;
                return err;
            };
            return;
        }

        if (responses.peekManagement()) |entry| {
            var history_result: ?*history.model.QueryResult = null;
            const payload = try encodeResponse(buffer, entry.response, panes, workspaces, &history_result);
            try startSessionSend(io, select, session, payload);
            if (history_result) |result| result.deinit();
            responses.removeAt(entry.offset);
            return;
        }

        if (responses.resync_workspace) |workspace| {
            const payload = try schema.encodeResyncRequired(buffer, .{
                .workspace = workspace,
                .workspace_closed = workspaces.find(workspace) == null,
            });
            try startSessionSend(io, select, session, payload);
            responses.resync_workspace = null;
            if (comptime diagnostics.enabled) metrics.client_resyncs += 1;
            return;
        }

        if (session.runtime_state_requested and !session.proxy_status_sent) {
            const payload = try schema.encodeProxyStatus(buffer, .{
                .active = server.proxy_service != null,
            });
            try startSessionSend(io, select, session, payload);
            session.proxy_status_sent = true;
            return;
        }

        if (session.runtime_state_requested and
            session.agent_revision_sent < server.agents.revision)
        {
            var entry_storage: [agent_mod.max_records]schema.AgentSnapshotEntry = undefined;
            const payload = try schema.encodeAgentSnapshot(buffer, .{
                .revision = server.agents.revision,
                .entries = server.agents.snapshot(&entry_storage),
            });
            try startSessionSend(io, select, session, payload);
            session.agent_revision_sent = server.agents.revision;
            return;
        }

        if (session.runtime_state_requested and
            session.system_metrics_revision_sent < server.system_metrics.revision)
        {
            if (server.system_metrics.latest) |values| {
                const payload = try schema.encodeSystemMetrics(buffer, .{
                    .revision = server.system_metrics.revision,
                    .cpu_percent = values.cpu_percent,
                    .memory_used_decigib = values.memory_used_decigib,
                    .has_battery = values.battery_percent != null,
                    .battery_percent = values.battery_percent orelse 0,
                });
                try startSessionSend(io, select, session, payload);
                session.system_metrics_revision_sent = server.system_metrics.revision;
                return;
            }
            // Nothing sampled yet: latch so a host without a metrics source
            // does not keep this branch hot on every pump.
            session.system_metrics_revision_sent = server.system_metrics.revision;
        }

        if (session.runtime_state_requested and
            session.workspace_list_revision_sent < workspaces.revision)
        {
            var entry_storage: [workspace_mod.max_workspaces]schema.WorkspaceListEntry = undefined;
            const payload = try schema.encodeWorkspaceList(buffer, .{
                .revision = workspaces.revision,
                .entries = workspaces.listEntries(&entry_storage),
            });
            try startSessionSend(io, select, session, payload);
            session.workspace_list_revision_sent = workspaces.revision;
            return;
        }

        var checked: usize = 0;
        while (checked < attachments.items.len) : (checked += 1) {
            const index = (attachments.next_send + checked) % attachments.items.len;
            const active = if (attachments.items[index]) |*value| value else continue;
            const pane = active.pane;
            if (pane.ingest_pending) continue;
            if (active.snapshot_pending) {
                const payload = (try encodeFrame(io, buffer, active, true, metrics)) orelse
                    unreachable;
                active.snapshot_pending = false;
                try startSessionSend(io, select, session, payload);
                attachments.next_send = (index + 1) % attachments.items.len;
                return;
            }
            if (active.outstanding_frame_id == 0 and
                (pane.dirty or active.observed_cell_revision != pane.cell_revision))
            {
                if (try encodeFrame(io, buffer, active, false, metrics)) |payload| {
                    try startSessionSend(io, select, session, payload);
                    attachments.next_send = (index + 1) % attachments.items.len;
                    return;
                }
            }
        }

        checked = 0;
        while (checked < attachments.items.len) : (checked += 1) {
            const index = (attachments.next_send + checked) % attachments.items.len;
            const active = if (attachments.items[index]) |*value| value else continue;
            const pane = active.pane;
            if (pane.ingest_pending) continue;
            if (!active.exit_sent and pane.output_done and pane.exit != null and
                active.outstanding_frame_id == 0)
            {
                const exit = pane.exit.?;
                const payload = try schema.encodePaneExited(buffer, .{
                    .pane_id = pane.id,
                    .kind = switch (exit) {
                        .exited => .exited,
                        .signaled => .signaled,
                    },
                    .value = switch (exit) {
                        .exited => |status| status,
                        .signaled => |signal| @intFromEnum(signal),
                    },
                });
                try startSessionSend(io, select, session, payload);
                active.exit_sent = true;
                session.sent_exit_pane = pane.id;
                attachments.next_send = (index + 1) % attachments.items.len;
                return;
            }
        }

        checked = 0;
        while (checked < attachments.items.len) : (checked += 1) {
            const index = (attachments.next_send + checked) % attachments.items.len;
            const active = if (attachments.items[index]) |*value| value else continue;
            const pane = active.pane;
            const frozen_transfer = active.transfer != null;
            if (pane.ingest_pending and !frozen_transfer) continue;
            if (pane.media.worker != null and !frozen_transfer) continue;
            if (active.graphics_snapshot != .idle or active.transfer != null or
                active.observed_graphics_revision != pane.graphics_revision)
            {
                // Media failure leaves the text terminal usable: give up on this
                // graphics revision, keep every cell frame flowing, and retry
                // when the pane's graphics actually change again.
                const graphics_payload = encodeNextGraphics(
                    buffer,
                    active,
                    availableGraphicsCredit(attachments),
                    pane.media.worker == null,
                ) catch payload: {
                    abandonGraphicsBatch(active);
                    break :payload null;
                };
                if (graphics_payload) |payload| {
                    if (comptime diagnostics.enabled) {
                        metrics.graphics_messages += 1;
                        metrics.graphics_bytes += payload.len;
                    }
                    try startSessionSend(io, select, session, payload);
                    attachments.next_send = (index + 1) % attachments.items.len;
                    return;
                }
            }
        }

        if (responses.peekObservation()) |entry| {
            var history_result: ?*history.model.QueryResult = null;
            const payload = try encodeResponse(buffer, entry.response, panes, workspaces, &history_result);
            try startSessionSend(io, select, session, payload);
            if (history_result) |result| result.deinit();
            responses.removeAt(entry.offset);
            return;
        }
    }

    /// Applies one decoded client command. Domain rejection is represented by
    /// `request_failed`; commands for an attachment that has already gone are
    /// counted and ignored. Therefore an error return is an infrastructure
    /// failure, never ordinary client or lifecycle state.
    fn dispatch(server: *Server, session: *ClientSession, message: schema.ClientMessage) !void {
        const io = server.io;
        const gpa = server.gpa;
        const select = server.select;
        const panes = &server.panes;
        const workspaces = &server.workspaces;
        const attachments = &session.attachments;
        const responses = &session.responses;
        const metrics = &server.metrics;
        const history_service = server.history_service;
        switch (message) {
            .open_pane => |open| {
                var created = false;
                const active = switch (open.target) {
                    .pane => |wanted| pane: {
                        const existing = panes.find(wanted) orelse {
                            try queueFailure(responses, open.request_id, .pane_not_found, "pane not found");
                            return;
                        };
                        if (existing.close_requested or existing.exit != null) {
                            try queueFailure(responses, open.request_id, .pane_not_found, "pane not found");
                            return;
                        }
                        break :pane existing;
                    },
                    .default => pane: {
                        const launch = open.launch.?;
                        const ensured = workspaces.ensure(launch.cwd) catch {
                            try queueFailure(responses, open.request_id, .resource_limit, "could not create workspace");
                            return;
                        };
                        var workspace_committed = !ensured.created;
                        const workspace_id = switch (ensured.location.workspace) {
                            .workspace => |id| id,
                            .worktree => unreachable,
                        };
                        defer if (!workspace_committed) workspaces.remove(workspace_id);
                        const location = ensured.location;
                        // `firstAt` never returns a closing or exited pane, so a
                        // hit is always reusable. Exited panes are reaped only by
                        // `collectFinished`, whose `readyToDestroy` guard proves
                        // no actor still borrows them; destroying one here on a
                        // weaker condition was a use-after-free waiting to happen.
                        if (panes.firstAt(location)) |existing| break :pane existing;
                        if (!server.holdsGeometry(session.key, location.workspace)) {
                            try queueFailure(
                                responses,
                                open.request_id,
                                .resource_limit,
                                "workspace geometry is leased by another client",
                            );
                            return;
                        }
                        const fresh = spawnPane(
                            io,
                            gpa,
                            select,
                            panes,
                            server.child_environment,
                            server.inherited_environment,
                            server.proxy_service,
                            location,
                            open.size,
                            launch,
                            history_service,
                        ) catch |err| {
                            if (err == error.RuntimeConcurrencyUnavailable) return err;
                            try queueSpawnFailure(responses, open.request_id, err);
                            return;
                        };
                        workspace_committed = true;
                        created = true;
                        break :pane fresh;
                    },
                };

                if (server.holdsGeometry(session.key, active.location.workspace)) {
                    const resize_result = if (active.ingest_pending)
                        active.requestResize(open.size)
                    else
                        active.resize(open.size);
                    resize_result catch {
                        try queueFailure(responses, open.request_id, .internal, "could not resize pane");
                        return;
                    };
                    try schedulePaneObservation(select, active);
                    try schedulePaneMedia(select, active);
                }
                const attachment = try attachments.attach(gpa, active);
                attachment.shared_transport = session.shared_graphics;
                _ = try attachment.resizeIfNeeded();
                try responses.push(.{ .pane_opened = .{
                    .request_id = open.request_id,
                    .pane_id = active.id,
                    .location = active.location,
                    .created = created,
                } });
            },
            .pane_input => |input| {
                const active = attachments.find(input.pane_id) orelse {
                    metrics.stale_client_messages += 1;
                    return;
                };
                if (active.pane.exit != null) {
                    metrics.stale_client_messages += 1;
                    return;
                }
                if (comptime diagnostics.enabled) {
                    metrics.input_events += 1;
                    metrics.input_bytes += input.bytes.len;
                }
                active.pane.queueHistoryInput(
                    input.bytes,
                    active.pane.session.shellForeground() orelse false,
                    historyClock(io),
                );
                try schedulePaneObservation(select, active.pane);
                _ = active.pane.input_queue.push(input.bytes);
                try schedulePaneInput(io, select, active.pane);
            },
            .pane_resize => |resize| {
                const active = attachments.find(resize.pane_id) orelse {
                    metrics.stale_client_messages += 1;
                    return;
                };
                if (!server.holdsGeometry(session.key, active.pane.location.workspace)) {
                    metrics.geometry_rejections += 1;
                    return;
                }
                try active.pane.requestResize(resize.size);
                if (!active.pane.ingest_pending) {
                    retirePaneOnFailure(active.pane, active.pane.applyPendingResize()) catch return;
                    try schedulePaneObservation(select, active.pane);
                    try schedulePaneMedia(select, active.pane);
                    _ = active.resizeIfNeeded() catch {
                        _ = attachments.detach(resize.pane_id);
                        return;
                    };
                }
                // Resizing may cause the emulator to emit an in-band resize
                // report. Treat it like every other terminal-produced response:
                // queue it behind the bounded PTY response writer.
                if (!active.pane.ingest_pending)
                    try schedulePaneResponse(io, select, active.pane);
            },
            .request_graphics_snapshot => |request| {
                const active = attachments.find(request.pane_id) orelse {
                    metrics.stale_client_messages += 1;
                    return;
                };
                active.resetGraphics();
            },
            .configure_graphics => |configure| {
                session.shared_graphics = configure.shared;
                for (&attachments.items) |*slot| {
                    const attachment = if (slot.*) |*value| value else continue;
                    attachment.shared_transport = configure.shared;
                }
            },
            .request_runtime_state => {
                session.runtime_state_requested = true;
            },
            .graphics_credit => |credit| {
                const active = attachments.find(credit.pane_id) orelse {
                    metrics.stale_client_messages += 1;
                    return;
                };
                const bytes = std.math.cast(usize, credit.bytes) orelse {
                    metrics.stale_client_messages += 1;
                    return;
                };
                if (bytes > core.graphics.max_image_bytes_per_pane - active.graphics_credit) {
                    metrics.stale_client_messages += 1;
                    return;
                }
                active.graphics_credit += bytes;
            },
            .frame_ack => |ack| {
                const active = attachments.find(ack.pane_id) orelse {
                    metrics.stale_client_messages += 1;
                    return;
                };
                if (ack.frame_id != active.outstanding_frame_id) {
                    metrics.stale_client_messages += 1;
                    return;
                }
                if (comptime diagnostics.enabled) {
                    metrics.ack.observe(diagnostics.elapsed(active.frame_sent_ns, diagnostics.now(io)));
                }
                active.acknowledged_frame_id = ack.frame_id;
                active.outstanding_frame_id = 0;
            },
            .request_snapshot => |request| {
                const active = attachments.find(request.pane_id) orelse {
                    metrics.stale_client_messages += 1;
                    return;
                };
                active.snapshot_pending = true;
            },
            .detach_pane => |detach| {
                const detached_workspace: ?schema.WorkspaceLocation =
                    if (attachments.find(detach.pane_id)) |active|
                        active.pane.location.workspace
                    else
                        null;
                if (!attachments.detach(detach.pane_id)) {
                    metrics.stale_client_messages += 1;
                } else if (detached_workspace) |left| {
                    // A client that walked away from a workspace gives its
                    // geometry lease back, so switching workspaces does not
                    // pin the abandoned one against other clients.
                    if (!attachments.observes(left))
                        server.releaseGeometryFor(session.key, left);
                }
            },
            .request_tab_snapshot => |request| {
                if (!workspaces.contains(request.location) or panes.countAt(request.location) == 0) {
                    try queueFailure(responses, request.request_id, .tab_not_found, "tab not found");
                    return;
                }
                try responses.push(.{ .tab_snapshot = .{
                    .request_id = request.request_id,
                    .location = request.location,
                } });
            },
            .create_pane => |create| {
                if (!workspaces.contains(create.location) or panes.countAt(create.location) == 0) {
                    try queueFailure(responses, create.request_id, .pane_not_found, "tab not found");
                    return;
                }
                if (!server.holdsGeometry(session.key, create.location.workspace)) {
                    try queueFailure(
                        responses,
                        create.request_id,
                        .resource_limit,
                        "workspace geometry is leased by another client",
                    );
                    return;
                }
                const fresh = spawnPane(
                    io,
                    gpa,
                    select,
                    panes,
                    server.child_environment,
                    server.inherited_environment,
                    server.proxy_service,
                    create.location,
                    create.size,
                    create.launch,
                    history_service,
                ) catch |err| {
                    if (err == error.RuntimeConcurrencyUnavailable) return err;
                    try queueSpawnFailure(responses, create.request_id, err);
                    return;
                };
                const attachment = try attachments.attach(gpa, fresh);
                attachment.shared_transport = session.shared_graphics;
                try responses.push(.{ .pane_opened = .{
                    .request_id = create.request_id,
                    .pane_id = fresh.id,
                    .location = fresh.location,
                    .created = true,
                } });
                server.notifyWorkspaceChanged(session.key, create.location.workspace);
            },
            .close_pane => |close| {
                const active = attachments.find(close.pane_id) orelse {
                    try queueFailure(responses, close.request_id, .pane_not_found, "pane not attached");
                    return;
                };
                if (!active.pane.close_requested) {
                    active.pane.close_requested = true;
                    active.pane.session.shutdown();
                }
            },
            .request_workspace_snapshot => |request| {
                if (workspaces.find(request.workspace) == null) {
                    try queueFailure(
                        responses,
                        request.request_id,
                        .workspace_not_found,
                        "workspace not found",
                    );
                    return;
                }
                try responses.push(.{ .workspace_snapshot = .{
                    .request_id = request.request_id,
                    .workspace = request.workspace,
                } });
            },
            .create_tab => |create| {
                if (!server.holdsGeometry(session.key, create.workspace)) {
                    try queueFailure(
                        responses,
                        create.request_id,
                        .resource_limit,
                        "workspace geometry is leased by another client",
                    );
                    return;
                }
                var generated_label: [schema.max_tab_label_bytes]u8 = undefined;
                const created = workspaces.createTab(
                    create.workspace,
                    create.label,
                    &generated_label,
                ) catch |err| {
                    switch (err) {
                        error.WorkspaceNotFound => try queueFailure(
                            responses,
                            create.request_id,
                            .workspace_not_found,
                            "workspace not found",
                        ),
                        error.TabLimitReached => try queueFailure(
                            responses,
                            create.request_id,
                            .resource_limit,
                            "tab limit reached",
                        ),
                        else => return err,
                    }
                    return;
                };
                var tab_committed = false;
                defer if (!tab_committed) {
                    _ = workspaces.removeTab(created.location);
                };
                const fresh = spawnPane(
                    io,
                    gpa,
                    select,
                    panes,
                    server.child_environment,
                    server.inherited_environment,
                    server.proxy_service,
                    created.location,
                    create.size,
                    create.launch,
                    history_service,
                ) catch |err| {
                    if (err == error.RuntimeConcurrencyUnavailable) return err;
                    try queueSpawnFailure(responses, create.request_id, err);
                    return;
                };
                const attachment = try attachments.attach(gpa, fresh);
                attachment.shared_transport = session.shared_graphics;
                const tab = workspaces.findTab(created.location).?;
                var pending: PendingTabCreated = .{
                    .request_id = create.request_id,
                    .location = created.location,
                    .position = created.position,
                    .label = undefined,
                    .label_len = @intCast(tab.labelSlice().len),
                    .root_pane_id = fresh.id,
                };
                @memcpy(pending.label[0..pending.label_len], tab.labelSlice());
                try responses.push(.{ .tab_created = pending });
                tab_committed = true;
                server.notifyWorkspaceChanged(session.key, create.workspace);
            },
            .rename_tab => |rename| {
                const tab = workspaces.findTab(rename.location) orelse {
                    try queueFailure(responses, rename.request_id, .tab_not_found, "tab not found");
                    return;
                };
                tab.setLabel(rename.label);
                var pending: PendingTabRenamed = .{
                    .request_id = rename.request_id,
                    .location = rename.location,
                    .label = undefined,
                    .label_len = @intCast(rename.label.len),
                };
                @memcpy(pending.label[0..pending.label_len], rename.label);
                try responses.push(.{ .tab_renamed = pending });
                server.notifyWorkspaceChanged(session.key, rename.location.workspace);
            },
            .close_tab => |close| {
                if (!workspaces.contains(close.location)) {
                    try queueFailure(responses, close.request_id, .tab_not_found, "tab not found");
                    return;
                }
                panes.closeAt(close.location);
                const workspace_closed = workspaces.removeTab(close.location).?;
                try responses.push(.{ .tab_closed = .{
                    .request_id = close.request_id,
                    .location = close.location,
                    .workspace_closed = workspace_closed,
                } });
                server.notifyWorkspaceChanged(session.key, close.location.workspace);
            },
            .move_tab => |move| {
                const workspace = workspaces.find(move.location.workspace) orelse {
                    try queueFailure(
                        responses,
                        move.request_id,
                        .workspace_not_found,
                        "workspace not found",
                    );
                    return;
                };
                const position = workspace.moveTab(move.location.tab_id, move.direction) orelse {
                    try queueFailure(responses, move.request_id, .tab_not_found, "tab not found");
                    return;
                };
                try responses.push(.{ .tab_moved = .{
                    .request_id = move.request_id,
                    .location = move.location,
                    .position = position,
                } });
                server.notifyWorkspaceChanged(session.key, move.location.workspace);
            },
            .query_history => |request| {
                const query = buildHistoryQuery(request, .{
                    .client = session.key,
                    .close_after_reply = session.role == .control,
                }) catch {
                    try queueFailure(
                        responses,
                        request.request_id,
                        .invalid_request,
                        "invalid history query",
                    );
                    return;
                };
                if (!history_service.query(io, query)) {
                    if (comptime diagnostics.enabled) metrics.history_query_failures += 1;
                    try queueFailure(
                        responses,
                        request.request_id,
                        .resource_limit,
                        "history queue is full",
                    );
                    return;
                }
                if (comptime diagnostics.enabled) metrics.history_queries += 1;
            },
            .runtime_stop => {
                server.requestShutdown(session.key);
            },
        }
    }
};

fn serveInternal(
    io: Io,
    gpa: std.mem.Allocator,
    endpoint: []const u8,
    options: ServeOptions,
) !void {
    try options.graphics.validate();
    graphics_sync.initSharedFreezeNonce(io);
    const history_path = options.history_path;
    const stop = options.stop;
    const ingest_gate = options.ingest_gate;
    var child_environment = try pty.Environment.init(gpa, options.environment, "telar");
    defer child_environment.deinit();
    const proxy_service = if (options.proxy) |proxy_options|
        try proxy_mod.service.Service.create(io, gpa, .{
            .key = proxy_options.key_path,
            .certificate = proxy_options.certificate_path,
            .bundle = proxy_options.bundle_path,
        })
    else
        null;
    var proxy_service_owned = proxy_service != null;
    errdefer if (proxy_service_owned) if (proxy_service) |service| service.destroy();
    var proxy_worker = if (proxy_service) |service|
        try io.concurrent(proxy_mod.service.Service.run, .{service})
    else
        null;
    defer if (proxy_service) |service| {
        if (proxy_worker) |*worker| worker.cancel(io) catch {};
        service.events.close(io);
        service.destroy();
        proxy_service_owned = false;
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

    var select_storage: [15 + 2 * max_clients + 7 * max_panes]RuntimeEvent = undefined;
    var select = Io.Select(RuntimeEvent).init(io, &select_storage);
    try select.concurrent(.accepted, acceptClient, .{ io, &listener });
    if (stop) |queue| try select.concurrent(.stopped, waitForStop, .{ io, queue });
    try select.concurrent(.history_response, history.receiveResponse, .{ io, &history_service });
    if (proxy_service) |service|
        try select.concurrent(.proxy_event, proxy_mod.service.Service.receive, .{ service, io });
    try select.concurrent(.agent_tick, waitForAgentTick, .{io});
    try select.concurrent(.metrics_tick, waitForMetricsTick, .{io});
    if (comptime diagnostics.enabled) {
        if (telemetry.available())
            try select.concurrent(.telemetry_tick, diagnostics.waitForTick, .{io});
    }

    var server: Server = .{
        .io = io,
        .gpa = gpa,
        .select = &select,
        .history_service = &history_service,
        .child_environment = &child_environment,
        .inherited_environment = options.environment,
        .proxy_service = proxy_service,
        .clients = clients,
        .workspaces = WorkspaceStore.init(gpa),
        .panes = .{
            .graphics_limits = options.graphics,
            .graphics_budget = .init(options.graphics.global_bytes),
        },
        .metrics = .{ .started_ns = diagnostics.now(io) },
    };
    var telemetry_buffer: [8192]u8 = undefined;
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
        server.panes.shutdown();
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
        server.panes.deinit();
        server.workspaces.deinit();
        history_service.closeQueues(io);
        _ = history_worker.await(io) catch {};
        history_service.deinit(io);
        history_owned = false;
    }

    while (true) switch (try select.await()) {
        .stopped => |result| return result,
        .accepted => |result| {
            var accepted = result catch {
                try select.concurrent(.accepted, acceptClient, .{ io, &listener });
                continue;
            };
            if (server.shutdown.requested) {
                accepted.deinit(io);
                continue;
            }
            try select.concurrent(.accepted, acceptClient, .{ io, &listener });
            // The handshake runs in its own actor so a connection that never
            // says hello cannot hold the accept pipeline hostage. One slot,
            // newest wins: an arriving client evicts a stalled handshake and
            // retries into the freed slot; a fast legitimate handshake is
            // gone from the slot before anyone else usually connects.
            if (server.handshake_pending) {
                if (server.handshake_slot) |*pending| pending.shutdown(io);
                accepted.deinit(io);
                continue;
            }
            server.handshake_slot = accepted;
            server.handshake_pending = true;
            select.concurrent(.handshaken, handshakeClient, .{
                io,
                &server.handshake_slot.?,
            }) catch {
                server.handshake_pending = false;
                server.handshake_slot.?.deinit(io);
                server.handshake_slot = null;
            };
        },
        .handshaken => |result| {
            server.handshake_pending = false;
            var negotiated = server.handshake_slot.?;
            server.handshake_slot = null;
            result catch {
                negotiated.deinit(io);
                continue;
            };
            if (server.shutdown.requested) {
                negotiated.deinit(io);
                continue;
            }
            const session = server.clients.add(gpa, negotiated) catch {
                negotiated.deinit(io);
                continue;
            };
            startSessionRead(io, &select, session) catch {
                server.dropClient(session.key);
            };
        },
        .client_message => |event| {
            const session = server.clients.resolve(event.client) orelse {
                server.metrics.stale_client_messages += 1;
                continue;
            };
            session.read_pending = false;
            if (session.closing) {
                server.finalizeClient(event.client);
                continue;
            }
            const payload = event.result catch {
                server.dropClient(event.client);
                continue;
            };
            const decode_started = diagnostics.now(io);
            const message = schema.decodeClient(payload) catch {
                server.dropClient(event.client);
                continue;
            };
            if (comptime diagnostics.enabled) {
                server.metrics.client_messages += 1;
                server.metrics.decode.observe(
                    diagnostics.elapsed(decode_started, diagnostics.now(io)),
                );
            }
            if (session.role == .undecided) session.role = switch (message) {
                .runtime_stop, .query_history => .control,
                else => .ui,
            };
            server.dispatch(session, message) catch |err| {
                if (err == error.RuntimeConcurrencyUnavailable) return err;
                server.dropClient(event.client);
                continue;
            };
            server.pump(session) catch {
                server.dropClient(event.client);
                continue;
            };
            if (!server.shutdown.requested) {
                startSessionRead(io, &select, session) catch
                    server.dropClient(event.client);
            } else {
                server.pumpAll();
                if (server.shutdownDelivered()) return;
            }
        },
        .client_sent => |event| {
            const session = server.clients.resolve(event.client) orelse {
                server.metrics.stale_client_messages += 1;
                continue;
            };
            session.send_pending = false;
            if (session.closing) {
                server.finalizeClient(event.client);
                if (server.shutdownDelivered()) return;
                continue;
            }
            event.result catch {
                server.dropClient(event.client);
                if (server.shutdownDelivered()) return;
                continue;
            };
            if (session.stopping_in_flight) session.stopping_in_flight = false;
            if (session.sent_exit_pane) |pane_id| {
                session.sent_exit_pane = null;
                _ = session.attachments.detach(pane_id);
                server.collect();
            }
            if (session.close_after_send and session.responses.len == 0 and
                !server.shutdown.requested)
            {
                server.dropClient(event.client);
                continue;
            }
            server.pump(session) catch server.dropClient(event.client);
            if (server.shutdown.requested) {
                server.pumpAll();
                if (server.shutdownDelivered()) return;
            }
        },
        .history_response => |response_result| {
            const response = response_result catch continue;
            try select.concurrent(.history_response, history.receiveResponse, .{
                io,
                &history_service,
            });
            switch (response) {
                .query_result => |result| {
                    const session = server.clients.resolve(result.origin.client) orelse {
                        result.deinit();
                        continue;
                    };
                    session.close_after_send = result.origin.close_after_reply;
                    session.responses.push(.{ .history_result = result }) catch
                        result.deinit();
                },
                .failed => |failure| {
                    const session = server.clients.resolve(failure.origin.client) orelse
                        continue;
                    session.close_after_send = failure.origin.close_after_reply;
                    queueFailure(
                        &session.responses,
                        failure.request_id,
                        .internal,
                        failure.message,
                    ) catch {};
                },
            }
            server.pumpAll();
        },
        .proxy_event => |event_result| {
            var event = event_result catch continue;
            defer std.crypto.secureZero(u8, &event.credential.token);
            if (proxy_service) |service|
                try select.concurrent(.proxy_event, proxy_mod.service.Service.receive, .{ service, io });
            const key: PaneKey = .{
                .id = event.credential.pane_id,
                .generation = event.credential.pane_generation,
            };
            const active = server.panes.resolve(key) orelse {
                server.metrics.stale_pane_events += 1;
                continue;
            };
            const expected = active.proxy_token orelse continue;
            if (!std.crypto.timing_safe.eql([proxy_mod.identity.token_bytes]u8, expected, event.credential.token))
                continue;
            if (comptime diagnostics.enabled) server.metrics.proxy_observations +|= 1;
            _ = server.agents.observeProxy(
                agent_mod.Identity.fromPane(active),
                event.provider,
                switch (event.phase) {
                    .request_started => .request_started,
                    .response_activity => .response_activity,
                    .response_finished => .response_finished,
                    .request_failed => .request_failed,
                },
                switch (event.protocol) {
                    .http11 => .http11,
                    .h2 => .h2,
                    .upgraded => .upgraded,
                },
                event.connection_id,
                event.stream_id,
                event.observed_at_ms,
            );
            server.pumpAll();
        },
        .agent_tick => |result| {
            result catch continue;
            try select.concurrent(.agent_tick, waitForAgentTick, .{io});
            _ = server.agents.expire(Io.Timestamp.now(io, .real).toMilliseconds());
            server.pumpAll();
        },
        .metrics_tick => |result| {
            result catch continue;
            try select.concurrent(.metrics_tick, waitForMetricsTick, .{io});
            server.system_metrics.sample();
            server.pumpAll();
        },
        .pane_input_written => |event| {
            const active = server.panes.resolve(event.pane) orelse {
                server.metrics.stale_pane_events += 1;
                continue;
            };
            active.actorFinished();
            active.input_write_pending = false;
            if (comptime diagnostics.enabled)
                server.metrics.input_write.observe(
                    diagnostics.elapsed(event.started_ns, diagnostics.now(io)),
                );
            if (event.result) |_| {
                active.input_queue.consume(event.len);
                try schedulePaneInput(io, &select, active);
            } else |_| {
                // The PTY is gone or refusing writes; the exit path owns the
                // pane's lifecycle, this queue only stops feeding it.
                active.input_queue.clear();
            }
            server.collect();
        },
        .pane_response_written => |event| {
            const active = server.panes.resolve(event.pane) orelse {
                server.metrics.stale_pane_events += 1;
                continue;
            };
            active.actorFinished();
            active.response_pending = false;
            if (event.result) |_| {
                active.pty_responses.pop();
                try schedulePaneResponse(io, &select, active);
            } else |_| {
                active.pty_responses.clear();
            }
            server.collect();
        },
        .pane_output => |event| {
            const active = server.panes.resolve(event.pane) orelse {
                server.metrics.stale_pane_events += 1;
                continue;
            };
            active.actorFinished();
            active.output_pending = false;
            const output_len = event.result catch {
                active.output_done = true;
                if (active.exit) |exit| {
                    active.queueExitedHistory(exit);
                    try schedulePaneObservation(&select, active);
                }
                server.collect();
                server.pumpAll();
                continue;
            };
            if (output_len == 0) {
                active.output_done = true;
                if (active.exit) |exit| {
                    active.queueExitedHistory(exit);
                    try schedulePaneObservation(&select, active);
                }
            } else {
                if (comptime diagnostics.enabled) {
                    server.metrics.pty_events += 1;
                    server.metrics.pty_bytes += output_len;
                    for (&server.clients.items) |*slot| {
                        const client = slot.* orelse continue;
                        const attachment = client.attachments.find(active.id) orelse continue;
                        if (attachment.outstanding_frame_id != 0) {
                            server.metrics.folded_pty_events += 1;
                            break;
                        }
                    }
                }
                active.queueHistoryOutput(
                    active.output_buffer[0..output_len],
                    active.session.shellForeground(),
                    historyClock(io),
                );
                try schedulePaneObservation(&select, active);
                active.queueMediaOutput(active.output_buffer[0..output_len]);
                try schedulePaneMedia(&select, active);
                active.ingest_pending = true;
                active.actorStarted();
                select.concurrent(.pane_ingested, ingestPane, .{
                    io,
                    active,
                    output_len,
                    ingest_gate,
                }) catch |err| {
                    active.actorFinished();
                    active.ingest_pending = false;
                    return err;
                };
                continue;
            }
            server.collect();
            server.pumpAll();
        },
        .pane_ingested => |event| {
            const active = server.panes.resolve(event.pane) orelse {
                server.metrics.stale_pane_events += 1;
                continue;
            };
            active.actorFinished();
            active.ingest_pending = false;
            const stats = event.result catch {
                active.close_requested = true;
                active.session.shutdown();
                active.output_done = true;
                server.collect();
                continue;
            };
            if (comptime diagnostics.enabled) {
                server.metrics.ingest.observe(stats.elapsed_ns);
            }
            retirePaneOnFailure(active, active.applyPendingResize()) catch {};
            try schedulePaneObservation(&select, active);
            try schedulePaneMedia(&select, active);
            for (&server.clients.items) |*slot| {
                const client = slot.* orelse continue;
                if (client.attachments.find(active.id)) |attachment| {
                    _ = attachment.resizeIfNeeded() catch {
                        _ = client.attachments.detach(active.id);
                    };
                }
            }
            try schedulePaneResponse(io, &select, active);
            active.output_pending = true;
            active.actorStarted();
            select.concurrent(.pane_output, readPane, .{ io, active }) catch |err| {
                active.actorFinished();
                active.output_pending = false;
                return err;
            };
            server.collect();
            server.pumpAll();
        },
        .pane_observed => |event| {
            const active = server.panes.resolve(event.pane) orelse {
                server.metrics.stale_pane_events += 1;
                continue;
            };
            active.actorFinished();
            active.history_observer.finishSealed();
            if (comptime diagnostics.enabled) {
                server.metrics.history_candidate_input_bytes +|= event.stats.input_bytes;
                server.metrics.history_captured +|= event.stats.captured;
                server.metrics.history_dropped +|= event.stats.dropped;
                if (event.stats.failed) server.metrics.history_observation_failures +|= 1;
                if (event.stats.reset) server.metrics.history_observation_resets +|= 1;
            }
            if (event.stats.agent_signal) |signal| {
                _ = server.agents.observeScreen(
                    agent_mod.Identity.fromPane(active),
                    .{
                        .provider = signal.provider,
                        .status = switch (signal.status) {
                            .working => .working,
                            .blocked => .blocked,
                            .ready => .ready,
                        },
                        .confidence = signal.confidence,
                    },
                    Io.Timestamp.now(io, .real).toMilliseconds(),
                );
            }
            try schedulePaneObservation(&select, active);
            server.collect();
            server.pumpAll();
        },
        .pane_media => |event| {
            const active = server.panes.resolve(event.pane) orelse {
                server.metrics.stale_pane_events += 1;
                continue;
            };
            active.actorFinished();
            active.media.finishSealed();
            if (comptime diagnostics.enabled) {
                server.metrics.media_bytes +|= event.stats.output_bytes;
                server.metrics.media_discarded_frames +|= event.stats.discarded_frames;
                if (event.stats.failed) server.metrics.media_failures +|= 1;
                if (event.stats.reset) server.metrics.media_resets +|= 1;
            }
            enforceGraphicsQuotas(io, active);
            active.observeGraphicsDamage();
            active.graphics_present =
                active.media.terminal.screens.active.kitty_images.images.count() != 0;
            if (event.stats.reset) {
                for (&server.clients.items) |*slot| {
                    const client = slot.* orelse continue;
                    if (client.attachments.find(active.id)) |attachment| attachment.resetGraphics();
                }
            }
            try schedulePaneResponse(io, &select, active);
            server.pumpAll();
            try schedulePaneMedia(&select, active);
            server.collect();
            server.pumpAll();
        },
        .pane_exit => |event| {
            const active = server.panes.resolve(event.pane) orelse {
                server.metrics.stale_pane_events += 1;
                continue;
            };
            active.actorFinished();
            active.wait_pending = false;
            active.exit = exitOrSynthetic(event.result);
            _ = server.agents.remove(active.key());
            if (server.proxy_service) |service| if (active.proxy_token) |*token| {
                service.unregisterCredential(.{
                    .pane_id = active.id,
                    .pane_generation = active.generation,
                    .token = token.*,
                });
                std.crypto.secureZero(u8, token);
                active.proxy_token = null;
            };
            server.panes.exited_count += 1;
            if (active.output_done) {
                active.queueExitedHistory(active.exit.?);
                try schedulePaneObservation(&select, active);
            }
            server.collect();
            server.pumpAll();
        },
        .telemetry_tick => |result| {
            result catch {
                telemetry.deinit(io);
                continue;
            };
            if (!telemetry.available()) continue;
            select.concurrent(.telemetry_tick, diagnostics.waitForTick, .{io}) catch {
                telemetry.deinit(io);
                continue;
            };
            if (telemetry_write_pending) continue;

            var attachment_stores: [max_clients]*const AttachmentStore = undefined;
            var attachment_store_count: usize = 0;
            var response_queue_depth: usize = 0;
            var response_queue_dropped: u64 = 0;
            for (&server.clients.items) |*slot| {
                const session = slot.* orelse continue;
                attachment_stores[attachment_store_count] = &session.attachments;
                attachment_store_count += 1;
                response_queue_depth += session.responses.len;
                response_queue_dropped +|= session.responses.dropped;
            }

            const line = formatRuntimeTelemetry(
                &telemetry_buffer,
                io,
                &server.metrics,
                attachment_stores[0..attachment_store_count],
                server.clients.count,
                server.workspaces.count,
                server.workspaces.totalTabs(),
                &server.panes,
                &history_service,
                response_queue_depth,
                response_queue_dropped,
                proxy_service != null,
                if (proxy_service) |service|
                    service.active_connections.load(.monotonic)
                else
                    0,
                if (proxy_service) |service|
                    service.dropped_events.load(.monotonic)
                else
                    0,
                if (proxy_service) |service|
                    service.rejected_connections.load(.monotonic)
                else
                    0,
                if (proxy_service) |service|
                    service.connection_limit_drops.load(.monotonic)
                else
                    0,
                if (proxy_service) |service|
                    service.h2_decode_failures.load(.monotonic)
                else
                    0,
            ) catch continue;
            telemetry_write_pending = true;
            select.concurrent(.telemetry_written, writeDiagnostics, .{
                io,
                &telemetry,
                line,
            }) catch {
                telemetry_write_pending = false;
                telemetry.deinit(io);
            };
        },
        .telemetry_written => |result| {
            telemetry_write_pending = false;
            result catch telemetry.deinit(io);
        },
    };
}

/// One construction rule for both the primary and the control query paths.
fn buildHistoryQuery(
    request: anytype,
    origin: history.model.QueryOrigin,
) !history.Query {
    return history.Query.init(
        request.request_id,
        origin,
        request.query,
        request.scope,
        request.scope_value,
        request.pane_id,
        request.failed_only,
        request.limit,
    );
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

fn queueSpawnFailure(
    responses: *ResponseQueue,
    request_id: schema.RequestId,
    spawn_error: anyerror,
) !void {
    switch (spawn_error) {
        error.PaneLimitReached => try queueFailure(
            responses,
            request_id,
            .resource_limit,
            "pane limit reached",
        ),
        error.UnsupportedEnvironment => try queueFailure(
            responses,
            request_id,
            .invalid_request,
            "unsupported launch environment",
        ),
        else => try queueFailure(
            responses,
            request_id,
            .spawn_failed,
            "could not start pane process",
        ),
    }
}

fn spawnPane(
    io: Io,
    gpa: std.mem.Allocator,
    select: *Io.Select(RuntimeEvent),
    panes: *PaneStore,
    environment: *const pty.Environment,
    inherited_environment: std.process.Environ,
    proxy_service: ?*proxy_mod.service.Service,
    location: schema.TabLocation,
    size: schema.TerminalSize,
    launch: schema.LaunchView,
    history_service: *history.Service,
) !*Pane {
    const pane_key = try panes.allocateKey();
    var proxy_environment: ?pty.Environment = null;
    defer if (proxy_environment) |*owned| owned.deinit();
    var proxy_token: ?[proxy_mod.identity.token_bytes]u8 = null;
    defer if (proxy_token) |*token| std.crypto.secureZero(u8, token);
    var proxy_credential: ?proxy_mod.identity.Credential = null;
    defer if (proxy_credential) |*credential| std.crypto.secureZero(u8, &credential.token);
    var proxy_registered = false;
    errdefer if (proxy_registered) if (proxy_service) |service|
        service.unregisterCredential(proxy_credential.?);
    const child_environment = if (proxy_service) |service| block: {
        var token = proxy_mod.identity.randomToken(io);
        defer std.crypto.secureZero(u8, &token);
        proxy_token = token;
        const credential: proxy_mod.identity.Credential = .{
            .pane_id = pane_key.id,
            .pane_generation = pane_key.generation,
            .token = token,
        };
        try service.registerCredential(credential);
        proxy_credential = credential;
        proxy_registered = true;
        var proxy_url_buffer: [256]u8 = undefined;
        defer std.crypto.secureZero(u8, &proxy_url_buffer);
        const proxy_url = try service.credentialUrl(&proxy_url_buffer, credential);
        const overrides = [_]pty.Environment.Override{
            .{ .name = "HTTPS_PROXY", .value = proxy_url },
            .{ .name = "https_proxy", .value = proxy_url },
            .{ .name = "NODE_USE_ENV_PROXY", .value = "1" },
            .{ .name = "NODE_EXTRA_CA_CERTS", .value = service.certificate_path },
            .{ .name = "SSL_CERT_FILE", .value = service.bundle_path },
            .{ .name = "CURL_CA_BUNDLE", .value = service.bundle_path },
            .{ .name = "REQUESTS_CA_BUNDLE", .value = service.bundle_path },
            .{ .name = "AWS_CA_BUNDLE", .value = service.bundle_path },
            .{ .name = "TELAR_PROXY_TLS", .value = "1" },
        };
        proxy_environment = try pty.Environment.initWithOverrides(
            gpa,
            inherited_environment,
            "telar",
            &overrides,
        );
        break :block &proxy_environment.?;
    } else environment;
    var command = try OwnedCommand.init(gpa, launch, child_environment);
    defer command.deinit();
    const fresh = fresh: {
        const created = try Pane.create(
            io,
            gpa,
            pane_key,
            location,
            &command.command,
            launch.cwd,
            history_service,
            size,
            panes.graphics_limits,
            &panes.graphics_budget,
        );
        errdefer created.destroy();
        try panes.insert(created);
        created.proxy_token = proxy_token;
        proxy_registered = false;
        break :fresh created;
    };
    select.concurrent(.pane_output, readPane, .{ io, fresh }) catch |err| {
        if (proxy_service) |service| if (fresh.proxy_token) |token|
            service.unregisterCredential(.{
                .pane_id = fresh.id,
                .pane_generation = fresh.generation,
                .token = token,
            });
        panes.removeAndDestroy(fresh);
        return err;
    };
    fresh.output_pending = true;
    fresh.actorStarted();
    select.concurrent(.pane_exit, waitPane, .{fresh}) catch {
        // The output actor already owns `fresh`, so this cannot be recovered
        // as a failed request without risking a use-after-free. Stop the
        // runtime; its normal teardown shuts down the PTY, joins the actor and
        // only then destroys the pane.
        fresh.close_requested = true;
        fresh.session.shutdown();
        return error.RuntimeConcurrencyUnavailable;
    };
    fresh.wait_pending = true;
    fresh.actorStarted();
    return fresh;
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

fn writePaneInput(io: Io, pane: *Pane, bytes: []const u8, started_ns: u64) PaneInputEvent {
    pane.pty_write_mutex.lockUncancelable(io);
    defer pane.pty_write_mutex.unlock(io);
    return .{
        .pane = pane.key(),
        .len = bytes.len,
        .started_ns = started_ns,
        .result = pane.session.file().writeStreamingAll(io, bytes),
    };
}

/// Feeds the pane's bounded input queue to its PTY, one in-flight write at a
/// time. A blocked write stalls only this pane: the client socket, every
/// other pane, and the event loop keep going.
fn schedulePaneInput(
    io: Io,
    select: *Io.Select(RuntimeEvent),
    pane: *Pane,
) !void {
    if (pane.input_write_pending) return;
    const chunk = pane.input_queue.nextChunk() orelse return;
    pane.input_write_pending = true;
    pane.actorStarted();
    select.concurrent(.pane_input_written, writePaneInput, .{
        io,
        pane,
        chunk,
        if (comptime diagnostics.enabled) diagnostics.now(io) else 0,
    }) catch |err| {
        pane.actorFinished();
        pane.input_write_pending = false;
        return err;
    };
}

fn schedulePaneResponse(
    io: Io,
    select: *Io.Select(RuntimeEvent),
    pane: *Pane,
) !void {
    if (pane.response_pending) return;
    const response = pane.pty_responses.peek() orelse return;
    pane.response_pending = true;
    pane.actorStarted();
    select.concurrent(.pane_response_written, writePaneResponse, .{
        io,
        pane,
        response,
    }) catch |err| {
        pane.actorFinished();
        pane.response_pending = false;
        return err;
    };
}

fn writePaneResponse(io: Io, pane: *Pane, bytes: []const u8) PaneResponseEvent {
    pane.pty_write_mutex.lockUncancelable(io);
    defer pane.pty_write_mutex.unlock(io);
    return .{
        .pane = pane.key(),
        .result = pane.session.file().writeStreamingAll(io, bytes),
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

fn readPane(io: Io, pane: *Pane) PaneOutputEvent {
    const len = pane.session.file().readStreaming(io, &.{&pane.output_buffer}) catch |err|
        return .{ .pane = pane.key(), .result = err };
    return .{ .pane = pane.key(), .result = @intCast(len) };
}

fn ingestPane(
    io: Io,
    pane: *Pane,
    output_len: u16,
    ingest_gate: ?*IngestTestGate,
) PaneIngestEvent {
    if (ingest_gate) |gate| gate.wait(io) catch |err|
        return .{ .pane = pane.key(), .result = err };
    var stats: PaneIngestStats = .{};
    stats.elapsed_ns = pane.ingest(io, pane.output_buffer[0..output_len]) catch |err|
        return .{ .pane = pane.key(), .result = err };
    return .{ .pane = pane.key(), .result = stats };
}

fn schedulePaneObservation(
    select: *Io.Select(RuntimeEvent),
    pane: *Pane,
) !void {
    if (!pane.history_observer.seal()) return;
    pane.actorStarted();
    select.concurrent(.pane_observed, observePane, .{ pane, pane.size }) catch |err| {
        pane.actorFinished();
        pane.history_observer.finishSealed();
        return err;
    };
}

fn observePane(pane: *Pane, current_size: schema.TerminalSize) PaneObservationEvent {
    var stats: history.observer.Stats = .{};
    pane.processHistoryObservation(current_size, &stats);
    return .{ .pane = pane.key(), .stats = stats };
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
    var stats: media_mod.Stats = .{};
    pane.processMedia(current_size, &stats);
    return .{ .pane = pane.key(), .stats = stats };
}

/// A resize that cannot get storage retires the affected pane - its state is
/// still coherent because the resize is transactional, but it can no longer
/// follow the client's geometry - and leaves every other pane running.
fn retirePaneOnFailure(pane: *Pane, result: anyerror!void) anyerror!void {
    result catch |err| {
        pane.close_requested = true;
        pane.session.shutdown();
        return err;
    };
}

/// A failed wait loses the exit status of one child, not the runtime: every
/// other pane must keep running, so the pane records a synthetic kill.
fn exitOrSynthetic(result: anyerror!pty.Exit) pty.Exit {
    return result catch .{ .signaled = .KILL };
}

fn waitPane(pane: *Pane) PaneExitEvent {
    const result = pane.session.wait();
    return .{ .pane = pane.key(), .result = result };
}

test "a wait failure becomes a synthetic exit instead of a runtime error" {
    try std.testing.expectEqual(
        pty.Exit{ .signaled = .KILL },
        exitOrSynthetic(error.WaitpidFailed),
    );
    try std.testing.expectEqual(
        pty.Exit{ .exited = 7 },
        exitOrSynthetic(pty.Exit{ .exited = 7 }),
    );
}

test "client session storage stays off the runtime stack" {
    try std.testing.expect(@sizeOf(ClientStore) < @sizeOf(ClientSession));

    const session = try ClientSession.create(
        std.testing.allocator,
        .{ .id = 1, .generation = 1 },
        .{ .stream = undefined },
    );
    defer {
        std.testing.allocator.free(session.receive_buffer);
        std.testing.allocator.free(session.send_buffer);
        std.testing.allocator.destroy(session);
    }

    try std.testing.expectEqual(@as(u64, 1), session.key.id);
    try std.testing.expectEqual(core.transport.max_frame_size, session.receive_buffer.len);
    try std.testing.expectEqual(core.transport.max_frame_size, session.send_buffer.len);
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
    var workspaces = WorkspaceStore.init(std.testing.allocator);
    defer workspaces.deinit();
    var panes: PaneStore = .{};
    var response: PendingResponse = .{ .workspace_snapshot = .{
        .request_id = @enumFromInt(9),
        .workspace = .{ .workspace = try schema.id.workspace(77) },
    } };
    var buffer: [1024]u8 = undefined;
    var history_result: ?*history.model.QueryResult = null;
    const payload = try encodeResponse(&buffer, &response, &panes, &workspaces, &history_result);
    const decoded = try schema.decodeServer(payload);
    try std.testing.expect(decoded == .request_failed);
    try std.testing.expectEqual(
        schema.FailureCode.workspace_not_found,
        decoded.request_failed.code,
    );
}

test "runtime VT answers KGP queries and decodes terminal-browser zlib RGBA" {
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
    _ = pane_mod;
    _ = workspace_mod;
    _ = graphics_sync;
    _ = telemetry_mod;
}
