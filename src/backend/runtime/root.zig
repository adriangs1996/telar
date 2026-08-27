//! Long-lived runtime for Telar's current schema.

const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");
const agent_mod = @import("../agent/root.zig");
const agent_process = @import("../process/root.zig");
const history = @import("../history/root.zig");
const graphics_sync = @import("graphics_sync.zig");
const pane_mod = @import("../pane/root.zig");
const blit = pane_mod.blit;
const media_mod = @import("../media/root.zig");
const pty = @import("../pty/root.zig");
const response_queue = @import("response_queue.zig");
const proxy_mod = @import("../proxy/root.zig");
const runtime_encoder = @import("encoder.zig");
pub const system_metrics = @import("system_metrics.zig");
const system_metrics_mod = system_metrics;
const telemetry_mod = @import("telemetry.zig");
const transport = @import("../transport/root.zig");
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
const PendingNotification = response_queue.PendingNotification;
const ResponseQueue = response_queue.ResponseQueue;
const encodeFrame = runtime_encoder.encodeFrame;
const encodeResponse = runtime_encoder.encodeResponse;

fn agentSoundForTransition(
    previous: ?schema.AgentStatus,
    current: ?schema.AgentStatus,
) ?schema.AgentSound {
    if (previous != .working) return null;
    return switch (current orelse return null) {
        .ready => .ready,
        .blocked => .needs_input,
        .unknown, .working, .failed => null,
    };
}

const AgentDisplayStorage = struct {
    workspace: [schema.max_agent_workspace_label_bytes]u8 = undefined,
    cwd: [schema.max_agent_cwd_label_bytes]u8 = undefined,
};

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

const proxy_environment_override_count = 11;

fn proxyEnvironmentOverrides(
    proxy_url: []const u8,
    certificate_path: []const u8,
    bundle_path: []const u8,
) [proxy_environment_override_count]pty.Environment.Override {
    return .{
        .{ .name = "HTTPS_PROXY", .value = proxy_url },
        .{ .name = "https_proxy", .value = proxy_url },
        .{ .name = "NODE_USE_ENV_PROXY", .value = "1" },
        .{ .name = "NODE_EXTRA_CA_CERTS", .value = certificate_path },
        .{ .name = "SSL_CERT_FILE", .value = bundle_path },
        .{ .name = "CURL_CA_BUNDLE", .value = bundle_path },
        .{ .name = "REQUESTS_CA_BUNDLE", .value = bundle_path },
        .{ .name = "AWS_CA_BUNDLE", .value = bundle_path },
        .{ .name = "GIT_SSL_CAINFO", .value = bundle_path },
        .{ .name = "CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE", .value = bundle_path },
        .{ .name = "TELAR_PROXY_TLS", .value = "1" },
    };
}

test "proxy environment covers Git and Google Cloud trust stores" {
    const overrides = proxyEnvironmentOverrides(
        "http://127.0.0.1:45100",
        "/state/ca-cert.pem",
        "/state/ca-bundle.pem",
    );
    try std.testing.expectEqualStrings("GIT_SSL_CAINFO", overrides[8].name);
    try std.testing.expectEqualStrings("/state/ca-bundle.pem", overrides[8].value);
    try std.testing.expectEqualStrings("CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE", overrides[9].name);
    try std.testing.expectEqualStrings("/state/ca-bundle.pem", overrides[9].value);
}

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
    process_probe: agent_process.Probe,
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
    agent_description: agent_mod.description.Result,
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
    clipboard_storage: [2 * schema.max_clipboard_bytes + 1]u8 = undefined,
    clipboard_len: u32 = 0,
    clipboard_pane: schema.PaneId = .invalid,
    clipboard_pending: bool = false,

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
        cwd_path: []const u8,
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
        const cwd = try gpa.dupeZ(u8, cwd_path);
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

/// One-shot integration seam for post-spawn launch recovery. Production entry
/// points never install this fault.
pub const LaunchTestFault = struct {
    phase: history.LaunchPhase,
    claimed: std.atomic.Value(bool) = .init(false),

    fn inject(fault: *LaunchTestFault, phase: history.LaunchPhase) !void {
        if (fault.phase != phase) return;
        if (fault.claimed.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
        return error.InjectedLaunchFailure;
    }
};

/// Everything one running runtime instance owns: the wire endpoints, the
/// stores, and the send state. Event arms and helpers used to thread a dozen
/// pointers each; they now share this struct.
const Server = struct {
    io: Io,
    gpa: std.mem.Allocator,
    heap: *diagnostics.Heap,
    select: *Io.Select(RuntimeEvent),
    history_service: *history.Service,
    child_environment: *const pty.Environment,
    inherited_environment: std.process.Environ,
    proxy_service: ?*proxy_mod.service.Service,
    agent_description_options: ?AgentDescriptionOptions,
    agent_description_pending: bool = false,
    launch_fault: ?*LaunchTestFault,
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

    fn injectLaunchFault(server: *Server, phase: history.LaunchPhase) !void {
        if (server.launch_fault) |fault| try fault.inject(phase);
    }

    fn recordLaunchFailure(
        server: *Server,
        pane: *const Pane,
        shell: []const u8,
        phase: history.LaunchPhase,
        cause: anyerror,
    ) void {
        _ = server.history_service.recordLaunchAttempt(
            server.io,
            pane.id,
            pane.generation,
            pane.location,
            pane.workspace_path,
            shell,
            pane.started_at_ms,
            phase,
            @errorName(cause),
        );
    }

    fn revokePaneCredential(server: *Server, pane: *Pane) void {
        const token = if (pane.proxy_token) |*value| value else return;
        if (server.proxy_service) |service| service.unregisterCredential(.{
            .pane_id = pane.id,
            .pane_generation = pane.generation,
            .token = token.*,
        });
        std.crypto.secureZero(u8, token);
        pane.proxy_token = null;
    }

    fn abortPaneLaunch(
        server: *Server,
        pane: *Pane,
        shell: []const u8,
        phase: history.LaunchPhase,
        cause: anyerror,
    ) void {
        server.recordLaunchFailure(pane, shell, phase, cause);
        server.revokePaneCredential(pane);
        pane.abortLaunch();
    }

    const CwdSourceScope = union(enum) {
        any,
        workspace: schema.WorkspaceLocation,
        tab: schema.TabLocation,
    };

    /// Resolves inherited cwd from runtime-owned pane state. The source must
    /// belong to this client and to the container affected by the operation.
    fn resolveLaunchCwd(
        session: *ClientSession,
        launch: schema.LaunchView,
        scope: CwdSourceScope,
    ) ![]const u8 {
        const source_id = launch.cwd_source orelse return launch.cwd;
        const attachment = session.attachments.find(source_id) orelse
            return error.CwdSourcePaneUnavailable;
        const pane = attachment.pane;
        if (pane.close_requested or pane.exit != null)
            return error.CwdSourcePaneUnavailable;
        switch (scope) {
            .any => {},
            .workspace => |workspace| if (!std.meta.eql(pane.location.workspace, workspace))
                return error.CwdSourceOutsideWorkspace,
            .tab => |location| if (!std.meta.eql(pane.location, location))
                return error.CwdSourceOutsideTab,
        }
        return pane.cwd.slice();
    }

    fn requestLaunchCwd(
        session: *ClientSession,
        responses: *ResponseQueue,
        request_id: schema.RequestId,
        launch: schema.LaunchView,
        scope: CwdSourceScope,
    ) !?[]const u8 {
        return resolveLaunchCwd(session, launch, scope) catch {
            try queueFailure(
                responses,
                request_id,
                .invalid_request,
                "cwd source pane is unavailable",
            );
            return null;
        };
    }

    /// Starts a pane and returns only after the runtime can observe both its
    /// output and exit. Client attachment and response delivery happen later.
    fn launchPane(
        server: *Server,
        location: schema.TabLocation,
        size: schema.TerminalSize,
        launch: schema.LaunchView,
        launch_cwd: []const u8,
        workspace_path: []const u8,
    ) !*Pane {
        const pane_key = try server.panes.allocateKey();
        var proxy_environment: ?pty.Environment = null;
        defer if (proxy_environment) |*owned| owned.deinit();
        var proxy_token: ?[proxy_mod.identity.token_bytes]u8 = null;
        defer if (proxy_token) |*token| std.crypto.secureZero(u8, token);
        var proxy_credential: ?proxy_mod.identity.Credential = null;
        defer if (proxy_credential) |*credential| std.crypto.secureZero(u8, &credential.token);
        var proxy_registered = false;
        errdefer if (proxy_registered) if (server.proxy_service) |service|
            service.unregisterCredential(proxy_credential.?);
        const child_environment = if (server.proxy_service) |service| block: {
            var token = proxy_mod.identity.randomToken(server.io);
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
            const overrides = proxyEnvironmentOverrides(
                proxy_url,
                service.certificate_path,
                service.bundle_path,
            );
            proxy_environment = try pty.Environment.initWithOverrides(
                server.gpa,
                server.inherited_environment,
                "telar",
                &overrides,
            );
            break :block &proxy_environment.?;
        } else server.child_environment;
        var command = try OwnedCommand.init(server.gpa, launch, launch_cwd, child_environment);
        defer command.deinit();
        const shell = std.mem.span(command.command.file);
        const fresh = try Pane.create(
            server.io,
            server.gpa,
            pane_key,
            location,
            &command.command,
            launch_cwd,
            workspace_path,
            server.history_service,
            size,
            server.panes.graphics_limits,
            &server.panes.graphics_budget,
        );

        server.panes.insert(fresh) catch |err| {
            server.recordLaunchFailure(fresh, shell, .pane_registration, err);
            fresh.abortLaunch();
            fresh.destroy();
            return err;
        };
        fresh.proxy_token = proxy_token;
        proxy_registered = false;
        server.injectLaunchFault(.pane_registration) catch |err| {
            server.abortPaneLaunch(fresh, shell, .pane_registration, err);
            server.panes.removeAndDestroy(fresh);
            return err;
        };

        // The wait actor goes first. If output scheduling then fails, this
        // actor owns process reaping while the aborting pane stays allocated.
        fresh.wait_pending = true;
        fresh.actorStarted();
        server.injectLaunchFault(.wait_actor) catch |err| {
            fresh.actorFinished();
            fresh.wait_pending = false;
            server.abortPaneLaunch(fresh, shell, .wait_actor, err);
            server.panes.removeAndDestroy(fresh);
            return err;
        };
        server.select.concurrent(.pane_exit, waitPane, .{fresh}) catch |err| {
            fresh.actorFinished();
            fresh.wait_pending = false;
            server.abortPaneLaunch(fresh, shell, .wait_actor, err);
            server.panes.removeAndDestroy(fresh);
            return err;
        };

        fresh.output_pending = true;
        fresh.actorStarted();
        server.injectLaunchFault(.output_actor) catch |err| {
            fresh.actorFinished();
            fresh.output_pending = false;
            fresh.output_done = true;
            server.abortPaneLaunch(fresh, shell, .output_actor, err);
            return err;
        };
        server.select.concurrent(.pane_output, readPane, .{ server.io, fresh }) catch |err| {
            fresh.actorFinished();
            fresh.output_pending = false;
            fresh.output_done = true;
            server.abortPaneLaunch(fresh, shell, .output_actor, err);
            return err;
        };

        fresh.commitLaunch(shell);
        server.agents.touch();
        return fresh;
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
                if (!server.agents.remove(pane.key())) server.agents.touch();
                server.revokePaneCredential(pane);
                pane.destroy();
                if (store.hasAt(location) or server.workspaces.findTab(location) == null) continue;

                const removal = server.workspaces.removeTab(location).?;
                for (&server.clients.items) |*client_slot| {
                    const client = client_slot.* orelse continue;
                    if (!client.active() or !client.attachments.observes(location.workspace)) continue;
                    client.responses.pushOrDrop(.{ .tab_closed = .{
                        .request_id = .none,
                        .location = location,
                        .workspace_closed = removal.workspace_closed,
                        .previous_workspace = removal.previous_workspace,
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
            if (!std.meta.eql(lease.owner, key)) continue;
            slot.* = null;
            // The lease is free but the runtime does not know any surviving
            // client's size. Resync the observers so one re-offers its
            // geometry and takes the lease over; without this the pane keeps
            // the departed client's size until an unrelated resize.
            server.notifyWorkspaceChanged(key, lease.workspace);
        }
    }

    fn releaseGeometryFor(
        server: *Server,
        key: ClientKey,
        workspace: schema.WorkspaceLocation,
    ) void {
        for (&server.geometry_leases) |*slot| {
            const lease = slot.* orelse continue;
            if (std.meta.eql(lease.owner, key) and std.meta.eql(lease.workspace, workspace)) {
                slot.* = null;
                server.notifyWorkspaceChanged(key, workspace);
            }
        }
    }

    fn notifyWorkspaceChanged(
        server: *Server,
        origin: ClientKey,
        workspace: schema.WorkspaceLocation,
    ) void {
        server.notifyWorkspaceChangedWithFallback(origin, workspace, null);
    }

    fn notifyWorkspaceClosed(
        server: *Server,
        origin: ClientKey,
        workspace: schema.WorkspaceLocation,
        previous_workspace: ?schema.WorkspaceId,
    ) void {
        server.notifyWorkspaceChangedWithFallback(origin, workspace, previous_workspace);
    }

    fn notifyWorkspaceChangedWithFallback(
        server: *Server,
        origin: ClientKey,
        workspace: schema.WorkspaceLocation,
        previous_workspace: ?schema.WorkspaceId,
    ) void {
        for (&server.clients.items) |*slot| {
            const session = slot.* orelse continue;
            if (std.meta.eql(session.key, origin) or !session.active()) continue;
            if (session.attachments.observes(workspace)) {
                session.responses.resync_workspace = workspace;
                session.responses.resync_previous_workspace = previous_workspace;
            }
        }
    }

    fn publishNotification(
        server: *Server,
        notification: schema.Notification,
    ) u8 {
        const pending = PendingNotification.init(notification);
        var delivered: u8 = 0;
        for (&server.clients.items) |*slot| {
            const recipient = slot.* orelse continue;
            if (!recipient.active() or recipient.role != .ui) continue;
            if (recipient.responses.pushNotification(pending)) delivered += 1;
        }
        return delivered;
    }

    fn publishAgentSound(server: *Server, notification: schema.AgentSoundNotification) void {
        for (&server.clients.items) |*slot| {
            const recipient = slot.* orelse continue;
            if (!recipient.active() or recipient.role != .ui) continue;
            _ = recipient.responses.pushAgentSound(notification);
        }
    }

    fn scheduleAgentDescription(server: *Server) void {
        const options = server.agent_description_options orelse return;
        if (server.agent_description_pending) return;
        var job = server.agents.nextDescriptionJob() orelse return;
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
            if (server.agents.finishDescription(&failed))
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
        if (server.agents.finishDescription(&result)) {
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
                .previous_workspace = responses.resync_previous_workspace,
            });
            try startSessionSend(io, select, session, payload);
            responses.resync_workspace = null;
            responses.resync_previous_workspace = null;
            if (comptime diagnostics.enabled) metrics.client_resyncs += 1;
            return;
        }

        if (session.clipboard_pending) {
            const payload = try schema.encodePaneClipboard(buffer, .{
                .pane_id = session.clipboard_pane,
                .bytes = session.clipboard_storage[0..session.clipboard_len],
            });
            session.clipboard_pending = false;
            try startSessionSend(io, select, session, payload);
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
            var display_storage: [agent_mod.max_records]AgentDisplayStorage = undefined;
            const entries = server.agents.snapshot(&entry_storage);
            var enriched_count: usize = 0;
            for (entries) |entry| {
                const pane = panes.resolve(.{
                    .id = entry.pane_id,
                    .generation = entry.pane_generation,
                }) orelse continue;
                const pane_index = panes.positionAt(pane) orelse continue;
                entry_storage[enriched_count] = entry;
                entry_storage[enriched_count].location = pane.location;
                entry_storage[enriched_count].pane_index = pane_index;
                if (workspaces.find(pane.location.workspace)) |workspace| {
                    entry_storage[enriched_count].workspace_label = copyDisplayPrefix(
                        &display_storage[enriched_count].workspace,
                        workspace.name(),
                    );
                }
                if (workspaces.findTab(pane.location)) |tab|
                    entry_storage[enriched_count].tab_label = tab.labelSlice();
                entry_storage[enriched_count].cwd_label = shortenCwd(
                    &display_storage[enriched_count].cwd,
                    pane.cwd.slice(),
                    server.inherited_environment.getPosix("HOME"),
                );
                enriched_count += 1;
            }
            const payload = try schema.encodeAgentSnapshot(buffer, .{
                .revision = server.agents.revision,
                .entries = entry_storage[0..enriched_count],
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
            if (active.observed_cwd_revision == pane.cwd.revision) continue;
            const payload = try schema.encodePaneCwd(buffer, .{
                .pane_id = pane.id,
                .cwd = pane.cwd.slice(),
            });
            active.observed_cwd_revision = pane.cwd.revision;
            try startSessionSend(io, select, session, payload);
            attachments.next_send = (index + 1) % attachments.items.len;
            return;
        }

        checked = 0;
        while (checked < attachments.items.len) : (checked += 1) {
            const index = (attachments.next_send + checked) % attachments.items.len;
            const active = if (attachments.items[index]) |*value| value else continue;
            const pane = active.pane;
            if (active.observed_foreground_revision == pane.foreground_revision) continue;
            const payload = try schema.encodePaneForeground(buffer, .{
                .pane_id = pane.id,
                .name = pane.agent_process_cache.name(),
            });
            active.observed_foreground_revision = pane.foreground_revision;
            try startSessionSend(io, select, session, payload);
            attachments.next_send = (index + 1) % attachments.items.len;
            return;
        }

        checked = 0;
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
                        metrics.graphics_images_sent +|= active.sent_images;
                        metrics.graphics_placements_sent +|= active.sent_placements;
                    }
                    active.sent_images = 0;
                    active.sent_placements = 0;
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
        if (session.role == .undecided) session.role = switch (message) {
            .runtime_stop, .query_history, .show_notification => .control,
            else => .ui,
        };
        server.dispatchClientMessage(session, message) catch {
            server.dropClient(event.client);
            return false;
        };
        server.pump(session) catch {
            server.dropClient(event.client);
            return false;
        };
        if (!server.shutdown.requested) {
            startSessionRead(server.io, server.select, session) catch
                server.dropClient(event.client);
            return false;
        }
        server.pumpAll();
        return server.shutdownDelivered();
    }

    /// Entrypoint for one completed PTY read. It records the raw output for
    /// observation and media, then hands terminal mutation to the ingest actor.
    fn handlePaneOutputEvent(
        server: *Server,
        event: PaneOutputEvent,
        ingest_gate: ?*IngestTestGate,
    ) !void {
        const active = server.panes.resolve(event.pane) orelse {
            server.metrics.stale_pane_events += 1;
            return;
        };
        active.actorFinished();
        active.output_pending = false;
        const output_len = event.result catch {
            active.output_done = true;
            if (active.exit) |exit| {
                active.queueExitedHistory(exit);
                try schedulePaneObservation(server.select, active);
            }
            server.collect();
            server.pumpAll();
            return;
        };
        if (output_len == 0) {
            active.output_done = true;
            if (active.exit) |exit| {
                active.queueExitedHistory(exit);
                try schedulePaneObservation(server.select, active);
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
                historyClock(server.io),
            );
            try schedulePaneObservation(server.select, active);
            active.queueMediaOutput(active.output_buffer[0..output_len]);
            try schedulePaneMedia(server.select, active);
            active.ingest_pending = true;
            active.actorStarted();
            server.select.concurrent(.pane_ingested, ingestPane, .{
                server.io,
                active,
                output_len,
                ingest_gate,
            }) catch |err| {
                active.actorFinished();
                active.ingest_pending = false;
                return err;
            };
            return;
        }
        server.collect();
        server.pumpAll();
    }

    /// Entrypoint for completed VT ingestion. It exposes the new cell/media
    /// state to attached clients and schedules the pane's next PTY read.
    fn handlePaneIngestedEvent(server: *Server, event: PaneIngestEvent) !void {
        const active = server.panes.resolve(event.pane) orelse {
            server.metrics.stale_pane_events += 1;
            return;
        };
        active.actorFinished();
        active.ingest_pending = false;
        const stats = event.result catch {
            active.close_requested = true;
            active.session.shutdown();
            active.output_done = true;
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
                    _ = client.attachments.detach(active.id);
                };
            }
        }
        try schedulePaneResponse(server.io, server.select, active);
        active.output_pending = true;
        active.actorStarted();
        server.select.concurrent(.pane_output, readPane, .{ server.io, active }) catch |err| {
            active.actorFinished();
            active.output_pending = false;
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
        if (server.shutdown.requested) {
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
        if (server.shutdown.requested) {
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
        event.result catch {
            server.dropClient(event.client);
            return server.shutdownDelivered();
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
            return false;
        }
        server.pump(session) catch server.dropClient(event.client);
        if (!server.shutdown.requested) return false;
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
                session.close_after_send = result.origin.close_after_reply;
                session.responses.push(.{ .history_result = result }) catch
                    result.deinit();
            },
            .failed => |failure| {
                const session = server.clients.resolve(failure.origin.client) orelse return;
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
    }

    fn handleProxyEvent(
        server: *Server,
        event_result: anyerror!proxy_mod.middleware.Event,
    ) !void {
        var event = event_result catch return;
        defer std.crypto.secureZero(u8, &event.credential.token);
        if (server.proxy_service) |service|
            try server.select.concurrent(
                .proxy_event,
                proxy_mod.service.Service.receive,
                .{ service, server.io },
            );
        const key: PaneKey = .{
            .id = event.credential.pane_id,
            .generation = event.credential.pane_generation,
        };
        const active = server.panes.resolve(key) orelse {
            server.metrics.stale_pane_events += 1;
            return;
        };
        const expected = active.proxy_token orelse return;
        if (!std.crypto.timing_safe.eql(
            [proxy_mod.identity.token_bytes]u8,
            expected,
            event.credential.token,
        )) return;
        if (comptime diagnostics.enabled) server.metrics.proxy_observations +|= 1;
        _ = server.agents.observeProxy(
            agent_mod.Identity.fromPane(active),
            event.provider,
            switch (event.phase) {
                .request_started => .request_started,
                .auxiliary_request_started => return,
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
        server.scheduleAgentDescription();
        server.pumpAll();
    }

    fn handleAgentTickEvent(server: *Server, result: anyerror!void) !void {
        result catch return;
        try server.select.concurrent(.agent_tick, waitForAgentTick, .{server.io});
        _ = server.agents.expire(Io.Timestamp.now(server.io, .real).toMilliseconds());
        server.pumpAll();
    }

    fn handleMetricsTickEvent(server: *Server, result: anyerror!void) !void {
        result catch return;
        try server.select.concurrent(.metrics_tick, waitForMetricsTick, .{server.io});
        server.system_metrics.sample();
        server.pumpAll();
    }

    fn handlePaneInputWrittenEvent(server: *Server, event: PaneInputEvent) !void {
        const active = server.panes.resolve(event.pane) orelse {
            server.metrics.stale_pane_events += 1;
            return;
        };
        active.actorFinished();
        active.input_write_pending = false;
        if (comptime diagnostics.enabled)
            server.metrics.input_write.observe(
                diagnostics.elapsed(event.started_ns, diagnostics.now(server.io)),
            );
        if (event.result) |_| {
            active.input_queue.consume(event.len);
            try schedulePaneInput(server.io, server.select, active);
        } else |_| {
            // The PTY is gone or refusing writes; the exit path owns the
            // pane's lifecycle, this queue only stops feeding it.
            active.input_queue.clear();
        }
        server.collect();
    }

    fn handlePaneResponseWrittenEvent(server: *Server, event: PaneResponseEvent) !void {
        const active = server.panes.resolve(event.pane) orelse {
            server.metrics.stale_pane_events += 1;
            return;
        };
        active.actorFinished();
        active.response_pending = false;
        if (event.result) |_| {
            active.pty_responses.pop();
            try schedulePaneResponse(server.io, server.select, active);
        } else |_| {
            active.pty_responses.clear();
        }
        server.collect();
    }

    fn handlePaneObservedEvent(server: *Server, event: PaneObservationEvent) !void {
        const active = server.panes.resolve(event.pane) orelse {
            server.metrics.stale_pane_events += 1;
            return;
        };
        active.actorFinished();
        active.history_observer.finishSealed();
        if (active.updateObservedCwd()) server.agents.touch();
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
                _ = server.agents.observeProcess(
                    agent_mod.Identity.fromPane(active),
                    event.process_probe.cache.provider,
                    event.process_probe.cache.process_group_id.?,
                    observed_at_ms,
                );
            } else if (agent_process.shellForeground(
                event.process_probe.cache,
                active.session.pid,
            )) {
                _ = server.agents.remove(active.key());
            } else if (previous_process.provider != .unknown) {
                _ = server.agents.clearProcess(active.key());
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
            const previous_status = server.agents.projectedStatus(identity.key);
            const changed = server.agents.observeScreen(
                identity,
                .{
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
                Io.Timestamp.now(server.io, .real).toMilliseconds(),
            );
            if (changed) if (agentSoundForTransition(
                previous_status,
                server.agents.projectedStatus(identity.key),
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
        const active = server.panes.resolve(event.pane) orelse {
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
                if (client.attachments.find(active.id)) |attachment| attachment.resetGraphics();
            }
        }
        // Freeze the next transfer while the media actor is idle so the send
        // loop can drain it whenever the transport becomes ready.
        for (&server.clients.items) |*slot| {
            const client = slot.* orelse continue;
            const attachment = client.attachments.find(active.id) orelse continue;
            if (attachment.transfer != null) continue;
            if (!attachment.graphics_batch_active and
                attachment.observed_graphics_revision == active.graphics_revision)
                continue;
            const staged = graphics_sync.stageNextTransfer(
                attachment,
                Server.availableGraphicsCredit(&client.attachments),
            ) catch blk: {
                abandonGraphicsBatch(attachment);
                break :blk .idle;
            };
            switch (staged) {
                .staged => if (comptime diagnostics.enabled) {
                    server.metrics.graphics_transfers_staged +|= 1;
                },
                .blocked, .idle => {},
            }
        }
        try schedulePaneResponse(server.io, server.select, active);
        server.pumpAll();
        try schedulePaneMedia(server.select, active);
        server.collect();
        server.pumpAll();
    }

    fn handlePaneExitEvent(server: *Server, event: PaneExitEvent) !void {
        const active = server.panes.resolve(event.pane) orelse {
            server.metrics.stale_pane_events += 1;
            return;
        };
        active.actorFinished();
        active.wait_pending = false;
        active.exit = exitOrSynthetic(event.result);
        _ = server.agents.remove(active.key());
        server.revokePaneCredential(active);
        server.panes.exited_count += 1;
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

    fn handleTelemetryTickEvent(
        server: *Server,
        result: anyerror!void,
        telemetry: *diagnostics.Sink,
        buffer: *[12288]u8,
        write_pending: *bool,
    ) void {
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
        var response_queue_dropped: u64 = 0;
        for (&server.clients.items) |*slot| {
            const session = slot.* orelse continue;
            attachment_stores[attachment_store_count] = &session.attachments;
            attachment_store_count += 1;
            response_queue_depth += session.responses.len;
            response_queue_dropped +|= session.responses.dropped;
        }

        const line = formatRuntimeTelemetry(
            buffer,
            server.io,
            &server.metrics,
            attachment_stores[0..attachment_store_count],
            server.clients.count,
            server.workspaces.count,
            server.workspaces.totalTabs(),
            &server.panes,
            server.history_service,
            response_queue_depth,
            response_queue_dropped,
            server.proxy_service != null,
            if (server.proxy_service) |service|
                service.active_connections.load(.monotonic)
            else
                0,
            if (server.proxy_service) |service|
                service.dropped_events.load(.monotonic)
            else
                0,
            if (server.proxy_service) |service|
                service.rejected_connections.load(.monotonic)
            else
                0,
            if (server.proxy_service) |service|
                service.invalid_authorization_rejections.load(.monotonic)
            else
                0,
            if (server.proxy_service) |service|
                service.unknown_credential_rejections.load(.monotonic)
            else
                0,
            if (server.proxy_service) |service|
                service.connection_limit_drops.load(.monotonic)
            else
                0,
            if (server.proxy_service) |service|
                service.h2_decode_failures.load(.monotonic)
            else
                0,
            if (server.proxy_service) |service|
                service.passthrough_connections.load(.monotonic)
            else
                0,
            if (server.proxy_service) |service|
                service.upstream_connect_failures.load(.monotonic)
            else
                0,
            if (server.proxy_service) |service|
                service.tls_context_failures.load(.monotonic)
            else
                0,
            if (server.proxy_service) |service|
                service.tls_upstream_handshake_failures.load(.monotonic)
            else
                0,
            if (server.proxy_service) |service|
                service.tls_downstream_handshake_failures.load(.monotonic)
            else
                0,
            if (server.proxy_service) |service|
                service.tls_mint_failures.load(.monotonic)
            else
                0,
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

    fn handleTelemetryWrittenEvent(
        server: *Server,
        result: anyerror!void,
        telemetry: *diagnostics.Sink,
        write_pending: *bool,
    ) void {
        write_pending.* = false;
        result catch telemetry.deinit(server.io);
    }

    fn dispatchClientMessage(
        server: *Server,
        session: *ClientSession,
        message: schema.ClientMessage,
    ) !void {
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
                        const existing = panes.findRunning(wanted) orelse {
                            try queueFailure(responses, open.request_id, .pane_not_found, "pane not found");
                            return;
                        };
                        if (existing.close_requested or existing.exit != null) {
                            try queueFailure(responses, open.request_id, .pane_not_found, "pane not found");
                            return;
                        }
                        break :pane existing;
                    },
                    .workspace => |wanted| pane: {
                        const workspace = workspaces.find(.{ .workspace = wanted }) orelse {
                            try queueFailure(
                                responses,
                                open.request_id,
                                .workspace_not_found,
                                "workspace not found",
                            );
                            return;
                        };
                        const location: schema.TabLocation = .{
                            .workspace = .{ .workspace = wanted },
                            .tab_id = workspace.defaultTab(),
                        };
                        const existing = panes.firstAt(location) orelse {
                            try queueFailure(
                                responses,
                                open.request_id,
                                .pane_not_found,
                                "workspace has no running pane",
                            );
                            return;
                        };
                        break :pane existing;
                    },
                    .default => pane: {
                        const launch = open.launch.?;
                        const launch_cwd = (try requestLaunchCwd(
                            session,
                            responses,
                            open.request_id,
                            launch,
                            .any,
                        )) orelse return;
                        const ensured = workspaces.ensure(launch_cwd) catch {
                            try queueFailure(responses, open.request_id, .resource_limit, "could not create workspace");
                            return;
                        };
                        var workspace_committed = !ensured.created;
                        const workspace_id = switch (ensured.location.workspace) {
                            .workspace => |id| id,
                            .worktree => unreachable,
                        };
                        defer if (!workspace_committed) {
                            workspaces.remove(workspace_id);
                            server.releaseGeometryFor(session.key, ensured.location.workspace);
                        };
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
                        const workspace_path = workspaces.find(location.workspace).?.path;
                        const fresh = server.launchPane(
                            location,
                            open.size,
                            launch,
                            launch_cwd,
                            workspace_path,
                        ) catch |err| {
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
            .create_workspace => |create| {
                const launch_cwd = (try requestLaunchCwd(
                    session,
                    responses,
                    create.request_id,
                    create.launch,
                    .any,
                )) orelse return;
                const location = workspaces.create(launch_cwd, create.name) catch {
                    try queueFailure(
                        responses,
                        create.request_id,
                        .resource_limit,
                        "could not create workspace",
                    );
                    return;
                };
                const workspace_id = switch (location.workspace) {
                    .workspace => |id| id,
                    .worktree => unreachable,
                };
                var workspace_committed = false;
                defer if (!workspace_committed) {
                    workspaces.remove(workspace_id);
                    server.releaseGeometryFor(session.key, location.workspace);
                };
                if (!server.holdsGeometry(session.key, location.workspace)) {
                    try queueFailure(
                        responses,
                        create.request_id,
                        .resource_limit,
                        "workspace geometry is unavailable",
                    );
                    return;
                }
                const fresh = server.launchPane(
                    location,
                    create.size,
                    create.launch,
                    launch_cwd,
                    launch_cwd,
                ) catch |err| {
                    try queueSpawnFailure(responses, create.request_id, err);
                    return;
                };
                workspace_committed = true;
                // A UI session observes one workspace. Preserve the current
                // attachments until the replacement pane is running, then
                // commit the handoff before acknowledging creation.
                const previous_workspace = attachments.workspace;
                attachments.deinit();
                if (previous_workspace) |previous|
                    server.releaseGeometryFor(session.key, previous);
                const attachment = try attachments.attach(gpa, fresh);
                attachment.shared_transport = session.shared_graphics;
                _ = try attachment.resizeIfNeeded();
                try responses.push(.{ .pane_opened = .{
                    .request_id = create.request_id,
                    .pane_id = fresh.id,
                    .location = fresh.location,
                    .created = true,
                } });
            },
            .rename_workspace => |rename| {
                workspaces.rename(rename.workspace, rename.name) catch |err| {
                    switch (err) {
                        error.WorkspaceNotFound => try queueFailure(
                            responses,
                            rename.request_id,
                            .workspace_not_found,
                            "workspace not found",
                        ),
                        else => try queueFailure(
                            responses,
                            rename.request_id,
                            .internal,
                            "could not rename workspace",
                        ),
                    }
                    return;
                };
                server.agents.touch();
                try responses.push(.{ .workspace_snapshot = .{
                    .request_id = rename.request_id,
                    .workspace = rename.workspace,
                } });
                server.notifyWorkspaceChanged(session.key, rename.workspace);
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
                if (server.agent_description_options != null)
                    _ = server.agents.observeInput(active.pane.key(), input.bytes);
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
            .set_pane_viewport => |viewport| {
                const active = attachments.find(viewport.pane_id) orelse {
                    metrics.stale_client_messages += 1;
                    return;
                };
                try active.setViewport(viewport.offset);
            },
            .copy_selection => |request| {
                const active = attachments.find(request.pane_id) orelse {
                    metrics.stale_client_messages += 1;
                    return;
                };
                const screen = active.pane.terminal.screens.active;
                const cols = active.pane.screen.w;
                const start_y = if (request.linewise)
                    @min(request.start_y, request.end_y)
                else
                    request.start_y;
                const end_y = if (request.linewise)
                    @max(request.start_y, request.end_y)
                else
                    request.end_y;
                const start_x: u16 = if (request.linewise) 0 else @min(request.start_x, cols - 1);
                const end_x: u16 = if (request.linewise) cols - 1 else @min(request.end_x, cols - 1);
                const start = screen.pages.pin(.{ .screen = .{
                    .x = start_x,
                    .y = start_y,
                } }) orelse screen.pages.getBottomRight(.screen) orelse return;
                const end = screen.pages.pin(.{ .screen = .{
                    .x = end_x,
                    .y = end_y,
                } }) orelse screen.pages.getBottomRight(.screen) orelse return;
                var allocator = std.heap.FixedBufferAllocator.init(&session.clipboard_storage);
                const selected = screen.selectionString(allocator.allocator(), .{
                    .sel = vt.Selection.init(start, end, false),
                }) catch return;
                if (selected.len > schema.max_clipboard_bytes) return;
                std.mem.copyForwards(u8, session.clipboard_storage[0..selected.len], selected);
                session.clipboard_len = @intCast(selected.len);
                session.clipboard_pane = request.pane_id;
                session.clipboard_pending = true;
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
                    if (attachments.count == 0) attachments.workspace = null;
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
                const launch_cwd = (try requestLaunchCwd(
                    session,
                    responses,
                    create.request_id,
                    create.launch,
                    .{ .tab = create.location },
                )) orelse return;
                const workspace_path = workspaces.find(create.location.workspace).?.path;
                const fresh = server.launchPane(
                    create.location,
                    create.size,
                    create.launch,
                    launch_cwd,
                    workspace_path,
                ) catch |err| {
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
                const launch_cwd = (try requestLaunchCwd(
                    session,
                    responses,
                    create.request_id,
                    create.launch,
                    .{ .workspace = create.workspace },
                )) orelse return;
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
                const fresh = server.launchPane(
                    created.location,
                    create.size,
                    create.launch,
                    launch_cwd,
                    workspaces.find(create.workspace).?.path,
                ) catch |err| {
                    try queueSpawnFailure(responses, create.request_id, err);
                    return;
                };
                tab_committed = true;
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
                server.notifyWorkspaceChanged(session.key, create.workspace);
            },
            .rename_tab => |rename| {
                const tab = workspaces.findTab(rename.location) orelse {
                    try queueFailure(responses, rename.request_id, .tab_not_found, "tab not found");
                    return;
                };
                tab.setLabel(rename.label);
                server.agents.touch();
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
                const removal = workspaces.removeTab(close.location).?;
                try responses.push(.{ .tab_closed = .{
                    .request_id = close.request_id,
                    .location = close.location,
                    .workspace_closed = removal.workspace_closed,
                    .previous_workspace = removal.previous_workspace,
                } });
                if (removal.workspace_closed) {
                    server.notifyWorkspaceClosed(
                        session.key,
                        close.location.workspace,
                        removal.previous_workspace,
                    );
                } else {
                    server.notifyWorkspaceChanged(session.key, close.location.workspace);
                }
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
            .show_notification => |request| {
                try responses.push(.{ .notification_shown = .{
                    .request_id = request.request_id,
                    .delivered_clients = 0,
                } });
                const delivered = server.publishNotification(request.notification);
                responses.setNotificationDelivery(request.request_id, delivered);
                server.pumpAll();
            },
            .runtime_stop => {
                server.requestShutdown(session.key);
            },
        }
    }
};

fn copyDisplayPrefix(output: []u8, source: []const u8) []const u8 {
    if (!validDisplayText(source)) return output[0..0];
    if (source.len <= output.len) {
        @memcpy(output[0..source.len], source);
        return output[0..source.len];
    }
    const ellipsis = "…";
    if (output.len < ellipsis.len) return output[0..0];
    var end = output.len - ellipsis.len;
    while (end != 0 and isUtf8Continuation(source[end])) end -= 1;
    @memcpy(output[0..end], source[0..end]);
    @memcpy(output[end..][0..ellipsis.len], ellipsis);
    return output[0 .. end + ellipsis.len];
}

fn shortenCwd(output: []u8, path: []const u8, home: ?[]const u8) []const u8 {
    if (!validDisplayText(path)) return output[0..0];
    var prefix: []const u8 = "";
    var suffix = path;
    if (home) |home_path| {
        if (home_path.len != 0 and std.mem.startsWith(u8, path, home_path) and
            (path.len == home_path.len or path[home_path.len] == '/'))
        {
            prefix = "~";
            suffix = path[home_path.len..];
        }
    }
    if (prefix.len + suffix.len <= output.len) {
        @memcpy(output[0..prefix.len], prefix);
        @memcpy(output[prefix.len..][0..suffix.len], suffix);
        return output[0 .. prefix.len + suffix.len];
    }

    const ellipsis = "…";
    if (output.len < ellipsis.len) return output[0..0];
    const available = output.len - ellipsis.len;
    var start = suffix.len -| available;
    while (start < suffix.len and isUtf8Continuation(suffix[start])) start += 1;
    const tail = suffix[start..];
    @memcpy(output[0..ellipsis.len], ellipsis);
    @memcpy(output[ellipsis.len..][0..tail.len], tail);
    return output[0 .. ellipsis.len + tail.len];
}

fn validDisplayText(bytes: []const u8) bool {
    if (bytes.len == 0 or !std.unicode.utf8ValidateSlice(bytes)) return false;
    for (bytes) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn isUtf8Continuation(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

fn serveInternal(
    io: Io,
    backing_gpa: std.mem.Allocator,
    endpoint: []const u8,
    options: ServeOptions,
) !void {
    var heap = diagnostics.Heap.init(backing_gpa);
    const gpa = heap.allocator();
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
            .passthrough_hosts = proxy_options.passthrough_hosts,
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

    var select_storage: [16 + 2 * max_clients + 7 * max_panes]RuntimeEvent = undefined;
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
        .heap = &heap,
        .select = &select,
        .history_service = &history_service,
        .child_environment = &child_environment,
        .inherited_environment = options.environment,
        .proxy_service = proxy_service,
        .agent_description_options = options.agent_descriptions,
        .launch_fault = options.launch_fault,
        .clients = clients,
        .workspaces = WorkspaceStore.init(gpa),
        .panes = .{
            .graphics_limits = options.graphics,
            .graphics_budget = .init(options.graphics.global_bytes),
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
    const path = diagnostics.enter(.interactive);
    defer path.restore();
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
    const path = diagnostics.enter(.interactive);
    defer path.restore();
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

test "agent display labels are bounded, valid UTF-8, and cwd-aware" {
    var workspace: [schema.max_agent_workspace_label_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "telar",
        copyDisplayPrefix(&workspace, "telar"),
    );
    try std.testing.expectEqual(@as(usize, 0), copyDisplayPrefix(&workspace, "bad\nname").len);

    const long_workspace = "abcdefghijklmnopqrstuvwxabcdefghijklmnopqrstuvé-more";
    const shortened_workspace = copyDisplayPrefix(&workspace, long_workspace);
    try std.testing.expect(shortened_workspace.len <= workspace.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(shortened_workspace));
    try std.testing.expect(std.mem.endsWith(u8, shortened_workspace, "…"));

    var cwd: [schema.max_agent_cwd_label_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "~/sandbox/telar",
        shortenCwd(&cwd, "/Users/adrian/sandbox/telar", "/Users/adrian"),
    );
    const long_cwd = "/Users/adrian/projects/abcdefghijklmnopqrstuvwx/abcdefghijklmnopqrstuvwx/agents/telar";
    const shortened_cwd = shortenCwd(&cwd, long_cwd, "/Users/adrian");
    try std.testing.expect(shortened_cwd.len <= cwd.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(shortened_cwd));
    try std.testing.expect(std.mem.startsWith(u8, shortened_cwd, "…"));
    try std.testing.expect(std.mem.endsWith(u8, shortened_cwd, "/agents/telar"));
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
    _ = pane_mod;
    _ = workspace_mod;
    _ = graphics_sync;
    _ = telemetry_mod;
}
