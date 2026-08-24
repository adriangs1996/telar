//! Long-lived runtime for Telar's current schema.

const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");
const blit = @import("blit.zig");
const damage = @import("damage.zig");
const history = @import("history/root.zig");
const graphics_sync = @import("graphics_sync.zig");
const pane_mod = @import("pane.zig");
const pty = @import("pty.zig");
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
const max_tabs_per_workspace = workspace_mod.max_tabs_per_workspace;
const Attachment = graphics_sync.Attachment;
const AttachmentStore = graphics_sync.AttachmentStore;
const abandonGraphicsBatch = graphics_sync.abandonGraphicsBatch;
const encodeNextGraphics = graphics_sync.encodeNextGraphics;
const enforceGraphicsQuotas = graphics_sync.enforceGraphicsQuotas;
const RuntimeMetrics = telemetry_mod.RuntimeMetrics;
const formatRuntimeTelemetry = telemetry_mod.formatRuntimeTelemetry;
const max_pending_responses = max_panes * 2;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub const ServeOptions = struct {
    graphics: GraphicsLimits = .{},
    /// SQLite database for durable history; the default keeps it in memory.
    history_path: [:0]const u8 = ":memory:",
    /// Test seam: stops the otherwise long-lived runtime without signals.
    stop: ?*Io.Queue(u8) = null,
    /// Test seam: holds a pane's ingest actor open. See `IngestTestGate`.
    ingest_gate: ?*IngestTestGate = null,
};

const PaneOutputEvent = struct {
    pane: PaneKey,
    result: anyerror!u16,
};

const PaneIngestEvent = struct {
    pane: PaneKey,
    result: anyerror!PaneIngestStats,
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
    client_message: anyerror![]u8,
    client_sent: anyerror!void,
    control_message: anyerror![]u8,
    control_sent: anyerror!void,
    history_response: anyerror!history.Response,
    pane_input_written: PaneInputEvent,
    pane_response_written: PaneResponseEvent,
    pane_output: PaneOutputEvent,
    pane_ingested: PaneIngestEvent,
    pane_exit: PaneExitEvent,
    telemetry_tick: anyerror!void,
    telemetry_written: anyerror!void,
    stopped: anyerror!void,
};

const PendingFailure = struct {
    request_id: schema.RequestId,
    code: schema.FailureCode,
    message: []const u8,
};

const PendingTabSnapshot = struct {
    request_id: schema.RequestId,
    location: schema.TabLocation,
};

const PendingWorkspaceSnapshot = struct {
    request_id: schema.RequestId,
    workspace: schema.WorkspaceLocation,
};

const PendingTabCreated = struct {
    request_id: schema.RequestId,
    location: schema.TabLocation,
    position: u16,
    label: [schema.max_tab_label_bytes]u8,
    label_len: u8,
    root_pane_id: schema.PaneId,

    fn labelSlice(created: *const PendingTabCreated) []const u8 {
        return created.label[0..created.label_len];
    }
};

const PendingTabRenamed = struct {
    request_id: schema.RequestId,
    location: schema.TabLocation,
    label: [schema.max_tab_label_bytes]u8,
    label_len: u8,

    fn labelSlice(renamed: *const PendingTabRenamed) []const u8 {
        return renamed.label[0..renamed.label_len];
    }
};

const PendingResponse = union(enum) {
    pane_opened: schema.PaneOpened,
    request_failed: PendingFailure,
    tab_snapshot: PendingTabSnapshot,
    workspace_snapshot: PendingWorkspaceSnapshot,
    tab_created: PendingTabCreated,
    tab_renamed: PendingTabRenamed,
    tab_closed: schema.TabClosed,
    tab_moved: schema.TabMoved,
    history_result: *history.model.QueryResult,
};

const ResponseQueue = struct {
    items: [max_pending_responses]PendingResponse = undefined,
    head: u8 = 0,
    len: u8 = 0,
    dropped: u64 = 0,
    resync_workspace: ?schema.WorkspaceLocation = null,

    const Entry = struct {
        offset: u8,
        response: *PendingResponse,
    };

    fn push(queue: *ResponseQueue, response: PendingResponse) !void {
        if (queue.len == queue.items.len) return error.ResponseQueueFull;
        const index = (@as(usize, queue.head) + queue.len) % queue.items.len;
        queue.items[index] = response;
        queue.len += 1;
    }

    /// For unsolicited notifications: a full queue means the client is
    /// behind, and the policy is to drop the notification and count it, never
    /// to escalate into tearing the runtime down. The client rebuilds tab
    /// state from snapshots when it catches up.
    fn pushOrDrop(queue: *ResponseQueue, response: PendingResponse) void {
        queue.push(response) catch {
            switch (response) {
                .history_result => |result| result.deinit(),
                .tab_closed => |closed| queue.resync_workspace = closed.location.workspace,
                .tab_moved => |moved| queue.resync_workspace = moved.location.workspace,
                else => {},
            }
            queue.dropped += 1;
        };
    }

    fn peek(queue: *ResponseQueue) ?*PendingResponse {
        if (queue.len == 0) return null;
        return &queue.items[queue.head];
    }

    fn peekManagement(queue: *ResponseQueue) ?Entry {
        for (0..queue.len) |offset| {
            const index = (@as(usize, queue.head) + offset) % queue.items.len;
            if (queue.items[index] == .history_result) continue;
            return .{ .offset = @intCast(offset), .response = &queue.items[index] };
        }
        return null;
    }

    fn peekObservation(queue: *ResponseQueue) ?Entry {
        for (0..queue.len) |offset| {
            const index = (@as(usize, queue.head) + offset) % queue.items.len;
            if (queue.items[index] != .history_result) continue;
            return .{ .offset = @intCast(offset), .response = &queue.items[index] };
        }
        return null;
    }

    fn pop(queue: *ResponseQueue) void {
        std.debug.assert(queue.len != 0);
        queue.head = @intCast((@as(usize, queue.head) + 1) % queue.items.len);
        queue.len -= 1;
    }

    fn removeAt(queue: *ResponseQueue, offset: u8) void {
        std.debug.assert(offset < queue.len);
        var cursor: usize = offset;
        while (cursor + 1 < queue.len) : (cursor += 1) {
            const destination = (@as(usize, queue.head) + cursor) % queue.items.len;
            const source = (@as(usize, queue.head) + cursor + 1) % queue.items.len;
            queue.items[destination] = queue.items[source];
        }
        queue.len -= 1;
    }

    fn clear(queue: *ResponseQueue) void {
        while (queue.peek()) |response| {
            switch (response.*) {
                .history_result => |result| result.deinit(),
                else => {},
            }
            queue.pop();
        }
        queue.head = 0;
        queue.resync_workspace = null;
    }
};

const ShutdownState = struct {
    requested: bool = false,
    primary_request: bool = false,
    reply_pending: bool = false,
    reply_in_flight: bool = false,
};

const ControlSend = enum {
    none,
    stop,
    history,
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

    fn init(gpa: std.mem.Allocator, launch: schema.LaunchView) !OwnedCommand {
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

        var command: pty.Command = .{ .file = arguments[0].ptr, .cwd = cwd.ptr };
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
    receive_buffer: []u8,
    send_buffer: []u8,
    control_buffer: []u8,
    connection: ?core.transport.SocketChannel = null,
    control_connection: ?core.transport.SocketChannel = null,
    handshake_slot: ?core.transport.SocketChannel = null,
    handshake_pending: bool = false,
    control_send: ControlSend = .none,
    client_read_pending: bool = false,
    client_send_pending: bool = false,
    attachments: AttachmentStore = .{},
    responses: ResponseQueue = .{},
    sent_exit_pane: ?schema.PaneId = null,
    shutdown: ShutdownState = .{},
    workspaces: WorkspaceStore,
    panes: PaneStore,
    metrics: RuntimeMetrics,

    fn activeConnection(server: *Server) ?*core.transport.SocketChannel {
        return if (server.connection) |*active|
            if (active.isActive()) active else null
        else
            null;
    }

    fn dropAttachments(server: *Server) void {
        server.attachments.deinit();
        server.collectFinished(null);
    }

    fn dropClient(server: *Server) void {
        if (server.connection) |*active| active.deinit(server.io);
        if (!server.client_read_pending and !server.client_send_pending)
            server.connection = null;
        server.dropAttachments();
    }

    fn dropControl(server: *Server) void {
        if (server.control_connection) |*active| active.deinit(server.io);
        server.control_connection = null;
    }

    /// Sends one reply on the control connection; an encode failure drops
    /// only the control connection.
    fn replyControl(server: *Server, payload_result: anyerror![]const u8) !void {
        const reply = payload_result catch {
            server.dropControl();
            return;
        };
        server.control_send = .history;
        try server.select.concurrent(.control_sent, sendClient, .{
            server.io,
            &server.control_connection.?,
            reply,
        });
    }

    fn collect(server: *Server) void {
        server.collectFinished(
            if (server.activeConnection() != null) &server.responses else null,
        );
    }

    /// Reaps panes whose child exited and which no actor still borrows, then
    /// closes tabs that ran out of panes. Spans three stores, which is why it
    /// lives on the server rather than on any one of them.
    fn collectFinished(server: *Server, responses: ?*ResponseQueue) void {
        const store = &server.panes;
        if (store.exited_count == 0) return;
        for (&store.items) |*slot| {
            const pane = slot.* orelse continue;
            if (!pane.readyToDestroy()) continue;
            if (server.attachments.find(pane.id) != null) continue;
            const location = pane.location;
            store.index.remove(schema.id.raw(pane.id));
            store.exited_count -= 1;
            slot.* = null;
            store.count -= 1;
            pane.destroy();
            if (store.hasAt(location) or server.workspaces.findTab(location) == null) continue;

            const workspace_closed = server.workspaces.removeTab(location).?;
            if (responses) |queue| {
                if (server.attachments.observes(location.workspace)) {
                    queue.pushOrDrop(.{ .tab_closed = .{
                        .request_id = .none,
                        .location = location,
                        .workspace_closed = workspace_closed,
                    } });
                }
            }
        }
    }

    fn pumpOrDrop(server: *Server) void {
        server.pump() catch server.dropClient();
    }

    fn pump(server: *Server) !void {
        const io = server.io;
        const select = server.select;
        const connection = server.activeConnection();
        const buffer = server.send_buffer;
        const attachments = &server.attachments;
        const panes = &server.panes;
        const workspaces = &server.workspaces;
        const responses = &server.responses;
        const send_pending = &server.client_send_pending;
        const sent_exit_pane = &server.sent_exit_pane;
        const shutdown = &server.shutdown;
        const metrics = &server.metrics;
        if (connection == null or send_pending.*) return;

        if (shutdown.reply_pending) {
            const payload = try schema.encodeRuntimeStopping(buffer);
            shutdown.reply_pending = false;
            shutdown.reply_in_flight = true;
            startSend(io, select, connection.?, payload, send_pending) catch |err| {
                shutdown.reply_in_flight = false;
                return err;
            };
            return;
        }

        if (responses.peekManagement()) |entry| {
            var history_result: ?*history.model.QueryResult = null;
            const payload = try encodeResponse(buffer, entry.response, panes, workspaces, &history_result);
            try startSend(io, select, connection.?, payload, send_pending);
            if (history_result) |result| result.deinit();
            responses.removeAt(entry.offset);
            return;
        }

        if (responses.resync_workspace) |workspace| {
            const payload = try schema.encodeResyncRequired(buffer, .{
                .workspace = workspace,
                .workspace_closed = workspaces.find(workspace) == null,
            });
            try startSend(io, select, connection.?, payload, send_pending);
            responses.resync_workspace = null;
            if (comptime diagnostics.enabled) metrics.client_resyncs += 1;
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
                try startSend(io, select, connection.?, payload, send_pending);
                attachments.next_send = (index + 1) % attachments.items.len;
                return;
            }
            if (active.outstanding_frame_id == 0 and pane.dirty) {
                if (try encodeFrame(io, buffer, active, false, metrics)) |payload| {
                    try startSend(io, select, connection.?, payload, send_pending);
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
                try startSend(io, select, connection.?, payload, send_pending);
                active.exit_sent = true;
                sent_exit_pane.* = pane.id;
                attachments.next_send = (index + 1) % attachments.items.len;
                return;
            }
        }

        checked = 0;
        while (checked < attachments.items.len) : (checked += 1) {
            const index = (attachments.next_send + checked) % attachments.items.len;
            const active = if (attachments.items[index]) |*value| value else continue;
            const pane = active.pane;
            if (pane.ingest_pending) continue;
            if (active.graphics_snapshot != .idle or active.transfer != null or
                active.observed_graphics_revision != pane.graphics_revision)
            {
                // Media failure leaves the text terminal usable: give up on this
                // graphics revision, keep every cell frame flowing, and retry
                // when the pane's graphics actually change again.
                const graphics_payload = encodeNextGraphics(buffer, active) catch payload: {
                    abandonGraphicsBatch(active);
                    break :payload null;
                };
                if (graphics_payload) |payload| {
                    if (comptime diagnostics.enabled) {
                        metrics.graphics_messages += 1;
                        metrics.graphics_bytes += payload.len;
                    }
                    try startSend(io, select, connection.?, payload, send_pending);
                    attachments.next_send = (index + 1) % attachments.items.len;
                    return;
                }
            }
        }

        if (responses.peekObservation()) |entry| {
            var history_result: ?*history.model.QueryResult = null;
            const payload = try encodeResponse(buffer, entry.response, panes, workspaces, &history_result);
            try startSend(io, select, connection.?, payload, send_pending);
            if (history_result) |result| result.deinit();
            responses.removeAt(entry.offset);
            return;
        }
    }

    /// Applies one decoded client command. Domain rejection is represented by
    /// `request_failed`; commands for an attachment that has already gone are
    /// counted and ignored. Therefore an error return is an infrastructure
    /// failure, never ordinary client or lifecycle state.
    fn dispatch(server: *Server, message: schema.ClientMessage) !void {
        const io = server.io;
        const gpa = server.gpa;
        const select = server.select;
        const panes = &server.panes;
        const workspaces = &server.workspaces;
        const attachments = &server.attachments;
        const responses = &server.responses;
        const shutdown = &server.shutdown;
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
                        const fresh = spawnPane(
                            io,
                            gpa,
                            select,
                            panes,
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

                const resize_result = if (active.ingest_pending)
                    active.requestResize(open.size)
                else
                    active.resize(open.size);
                resize_result catch {
                    try queueFailure(responses, open.request_id, .internal, "could not resize pane");
                    return;
                };
                const attachment = try attachments.attach(gpa, active);
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
                _ = active.pane.input_queue.push(input.bytes);
                try schedulePaneInput(io, select, active.pane);
            },
            .pane_resize => |resize| {
                const active = attachments.find(resize.pane_id) orelse {
                    metrics.stale_client_messages += 1;
                    return;
                };
                try active.pane.requestResize(resize.size);
                if (!active.pane.ingest_pending) {
                    retirePaneOnFailure(active.pane, active.pane.applyPendingResize()) catch return;
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
                if (!attachments.detach(detach.pane_id))
                    metrics.stale_client_messages += 1;
            },
            .request_tab_snapshot => |request| {
                if (!workspaces.contains(request.location)) {
                    try queueFailure(responses, request.request_id, .tab_not_found, "tab not found");
                    return;
                }
                try responses.push(.{ .tab_snapshot = .{
                    .request_id = request.request_id,
                    .location = request.location,
                } });
            },
            .create_pane => |create| {
                if (!workspaces.contains(create.location)) {
                    try queueFailure(responses, create.request_id, .pane_not_found, "tab not found");
                    return;
                }
                const fresh = spawnPane(
                    io,
                    gpa,
                    select,
                    panes,
                    create.location,
                    create.size,
                    create.launch,
                    history_service,
                ) catch |err| {
                    if (err == error.RuntimeConcurrencyUnavailable) return err;
                    try queueSpawnFailure(responses, create.request_id, err);
                    return;
                };
                _ = try attachments.attach(gpa, fresh);
                try responses.push(.{ .pane_opened = .{
                    .request_id = create.request_id,
                    .pane_id = fresh.id,
                    .location = fresh.location,
                    .created = true,
                } });
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
                    created.location,
                    create.size,
                    create.launch,
                    history_service,
                ) catch |err| {
                    if (err == error.RuntimeConcurrencyUnavailable) return err;
                    try queueSpawnFailure(responses, create.request_id, err);
                    return;
                };
                _ = try attachments.attach(gpa, fresh);
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
            },
            .query_history => |request| {
                const query = buildHistoryQuery(request, .primary) catch {
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
                shutdown.requested = true;
                shutdown.primary_request = true;
                shutdown.reply_pending = true;
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
    const history_path = options.history_path;
    const stop = options.stop;
    const ingest_gate = options.ingest_gate;
    _ = setenv("TERM", "xterm-256color", 1);
    _ = setenv("TERM_PROGRAM", "telar", 1);

    var listener = try transport.local.LocalListener.listen(io, endpoint);
    var telemetry_suffix_buffer: [64]u8 = undefined;
    const telemetry_suffix = std.fmt.bufPrint(
        &telemetry_suffix_buffer,
        "runtime-{d}",
        .{std.c.getpid()},
    ) catch "runtime";
    var telemetry = diagnostics.Sink.init(io, endpoint, telemetry_suffix);
    defer telemetry.deinit(io);

    const receive_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    defer gpa.free(receive_buffer);
    const send_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    defer gpa.free(send_buffer);
    const control_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    defer gpa.free(control_buffer);

    var history_service = try history.Service.init(gpa, history_path);
    var history_worker = try io.concurrent(history.runWorker, .{ io, &history_service });
    var history_owned = true;
    errdefer if (history_owned) {
        history_service.closeQueues(io);
        _ = history_worker.await(io) catch {};
        history_service.deinit(io);
    };

    var select_storage: [17 + 5 * max_panes]RuntimeEvent = undefined;
    var select = Io.Select(RuntimeEvent).init(io, &select_storage);
    try select.concurrent(.accepted, acceptClient, .{ io, &listener });
    if (stop) |queue| try select.concurrent(.stopped, waitForStop, .{ io, queue });
    try select.concurrent(.history_response, history.receiveResponse, .{ io, &history_service });
    if (comptime diagnostics.enabled) {
        if (telemetry.available())
            try select.concurrent(.telemetry_tick, diagnostics.waitForTick, .{io});
    }

    var server: Server = .{
        .io = io,
        .gpa = gpa,
        .select = &select,
        .history_service = &history_service,
        .receive_buffer = receive_buffer,
        .send_buffer = send_buffer,
        .control_buffer = control_buffer,
        .workspaces = WorkspaceStore.init(gpa),
        .panes = .{
            .graphics_limits = options.graphics,
            .graphics_budget = .init(options.graphics.global_bytes),
        },
        .metrics = .{ .started_ns = diagnostics.now(io) },
    };
    var telemetry_buffer: [4096]u8 = undefined;
    var telemetry_write_pending = false;
    defer {
        listener.shutdown();
        if (server.connection) |*active| active.shutdown(io);
        if (server.control_connection) |*active| active.shutdown(io);
        if (server.handshake_slot) |*pending| pending.shutdown(io);
        // `pane_exit` blocks in libc's waitpid and cannot observe Select
        // cancellation. End the PTY sessions first so their waits can finish;
        // masters stay open here and close in `destroy`, after every actor
        // has been joined, because Darwin's close waits behind blocked writes.
        server.panes.shutdown();
        select.cancelDiscard();
        listener.deinit(io);
        if (server.connection) |*active| active.deinit(io);
        if (server.control_connection) |*active| active.deinit(io);
        if (server.handshake_slot) |*pending| pending.deinit(io);
        server.attachments.deinit();
        server.panes.deinit();
        server.workspaces.deinit();
        server.responses.clear();
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
            if (server.connection != null) {
                if (server.control_connection != null) {
                    negotiated.deinit(io);
                    continue;
                }
                server.control_connection = negotiated;
                try select.concurrent(.control_message, receiveClient, .{
                    io,
                    &server.control_connection.?,
                    control_buffer,
                });
                continue;
            }
            server.connection = negotiated;
            server.responses.clear();
            server.dropAttachments();
            server.sent_exit_pane = null;
            server.client_read_pending = true;
            try select.concurrent(.client_message, receiveClient, .{
                io,
                &server.connection.?,
                receive_buffer,
            });
        },
        .client_message => |result| {
            server.client_read_pending = false;
            const payload = result catch {
                server.connection.?.deinit(io);
                if (!server.client_send_pending) server.connection = null;
                server.dropAttachments();
                server.responses.clear();
                continue;
            };
            const decode_started = diagnostics.now(io);
            const message = schema.decodeClient(payload) catch {
                server.connection.?.deinit(io);
                if (!server.client_send_pending) server.connection = null;
                server.dropAttachments();
                continue;
            };
            if (comptime diagnostics.enabled) {
                server.metrics.client_messages += 1;
                server.metrics.decode.observe(
                    diagnostics.elapsed(decode_started, diagnostics.now(io)),
                );
            }
            server.dispatch(message) catch |err| {
                if (err == error.RuntimeConcurrencyUnavailable) return err;
                if (server.shutdown.primary_request) return;
                server.connection.?.deinit(io);
                if (!server.client_send_pending) server.connection = null;
                server.dropAttachments();
                continue;
            };
            server.pump() catch {
                if (server.shutdown.primary_request) return;
                server.dropClient();
                continue;
            };
            if (!server.shutdown.requested) {
                server.client_read_pending = true;
                try select.concurrent(.client_message, receiveClient, .{
                    io,
                    &server.connection.?,
                    receive_buffer,
                });
            }
        },
        .client_sent => |result| {
            server.client_send_pending = false;
            if (server.shutdown.reply_in_flight) {
                server.shutdown.reply_in_flight = false;
                _ = result catch {};
                return;
            }
            result catch {
                if (server.shutdown.primary_request) return;
                server.dropClient();
                continue;
            };
            if (server.sent_exit_pane) |pane_id| {
                server.sent_exit_pane = null;
                _ = server.attachments.detach(pane_id);
                server.collect();
            }
            if (server.connection == null or !server.connection.?.isActive()) {
                if (!server.client_read_pending) server.connection = null;
                continue;
            }
            server.pump() catch {
                if (server.shutdown.primary_request) return;
                server.dropClient();
            };
        },
        .control_message => |result| {
            const payload = result catch {
                server.dropControl();
                continue;
            };
            const message = schema.decodeClient(payload) catch {
                server.dropControl();
                continue;
            };
            switch (message) {
                .runtime_stop => {
                    server.shutdown.requested = true;
                    const reply = try schema.encodeRuntimeStopping(control_buffer);
                    server.control_send = .stop;
                    select.concurrent(.control_sent, sendClient, .{
                        io,
                        &server.control_connection.?,
                        reply,
                    }) catch |err| {
                        return err;
                    };
                },
                .query_history => |request| {
                    const query = buildHistoryQuery(request, .control) catch {
                        try server.replyControl(schema.encodeRequestFailed(control_buffer, .{
                            .request_id = request.request_id,
                            .code = .invalid_request,
                            .message = "invalid history query",
                        }));
                        continue;
                    };
                    if (!history_service.query(io, query)) {
                        if (comptime diagnostics.enabled) server.metrics.history_query_failures += 1;
                        try server.replyControl(schema.encodeRequestFailed(control_buffer, .{
                            .request_id = request.request_id,
                            .code = .resource_limit,
                            .message = "history queue is full",
                        }));
                        continue;
                    }
                    if (comptime diagnostics.enabled) server.metrics.history_queries += 1;
                },
                else => server.dropControl(),
            }
        },
        .control_sent => |result| {
            _ = result catch {};
            if (server.control_send == .history) {
                server.control_send = .none;
                server.dropControl();
                continue;
            }
            server.control_send = .none;
            // A control client gets the acknowledgement first. The attached
            // UI then gets an explicit shutdown message so it can leave raw
            // mode cleanly instead of interpreting EOF as a runtime failure.
            server.shutdown.primary_request = true;
            server.shutdown.reply_pending = true;
            server.pump() catch return;
            if (!server.client_send_pending) return;
        },
        .history_response => |response_result| {
            const response = response_result catch continue;
            try select.concurrent(.history_response, history.receiveResponse, .{
                io,
                &history_service,
            });
            switch (response) {
                .query_result => |result| switch (result.origin) {
                    .primary => server.responses.push(.{ .history_result = result }) catch {
                        result.deinit();
                    },
                    .control => {
                        defer result.deinit();
                        if (server.control_connection == null) continue;
                        var entries: [history.model.max_results]schema.HistoryEntry = undefined;
                        try server.replyControl(
                            encodeHistoryResult(control_buffer, result, &entries),
                        );
                    },
                },
                .failed => |failure| switch (failure.origin) {
                    .primary => queueFailure(
                        &server.responses,
                        failure.request_id,
                        .internal,
                        failure.message,
                    ) catch {},
                    .control => {
                        if (server.control_connection == null) continue;
                        try server.replyControl(schema.encodeRequestFailed(control_buffer, .{
                            .request_id = failure.request_id,
                            .code = .internal,
                            .message = failure.message,
                        }));
                    },
                },
            }
            server.pumpOrDrop();
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
                if (active.exit) |exit| active.finishExitedHistory(exit, &server.metrics);
                server.collect();
                server.pumpOrDrop();
                continue;
            };
            if (output_len == 0) {
                active.output_done = true;
                if (active.exit) |exit| active.finishExitedHistory(exit, &server.metrics);
            } else {
                if (comptime diagnostics.enabled) {
                    server.metrics.pty_events += 1;
                    server.metrics.pty_bytes += output_len;
                    if (server.attachments.find(active.id)) |value| {
                        if (value.outstanding_frame_id != 0)
                            server.metrics.folded_pty_events += 1;
                    }
                }
                active.sealHistoryInput();
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
            server.pumpOrDrop();
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
                server.metrics.history_candidate_input_bytes += stats.history_input_bytes;
                server.metrics.history_captured += stats.history_captured;
                server.metrics.history_dropped += stats.history_dropped;
            }
            retirePaneOnFailure(active, active.applyPendingResize()) catch {};
            if (server.attachments.find(active.id)) |attachment| {
                _ = attachment.resizeIfNeeded() catch {
                    _ = server.attachments.detach(active.id);
                };
            }
            enforceGraphicsQuotas(io, active);
            active.observeGraphicsDamage();
            try schedulePaneResponse(io, &select, active);
            active.output_pending = true;
            active.actorStarted();
            select.concurrent(.pane_output, readPane, .{ io, active }) catch |err| {
                active.actorFinished();
                active.output_pending = false;
                return err;
            };
            server.collect();
            server.pumpOrDrop();
        },
        .pane_exit => |event| {
            const active = server.panes.resolve(event.pane) orelse {
                server.metrics.stale_pane_events += 1;
                continue;
            };
            active.actorFinished();
            active.wait_pending = false;
            active.exit = exitOrSynthetic(event.result);
            server.panes.exited_count += 1;
            if (active.output_done) active.finishExitedHistory(active.exit.?, &server.metrics);
            server.collect();
            server.pumpOrDrop();
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

            const line = formatRuntimeTelemetry(
                &telemetry_buffer,
                io,
                &server.metrics,
                &server.attachments,
                server.workspaces.count,
                server.workspaces.totalTabs(),
                &server.panes,
                &history_service,
                server.responses.len,
                server.responses.dropped,
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
    location: schema.TabLocation,
    size: schema.TerminalSize,
    launch: schema.LaunchView,
    history_service: *history.Service,
) !*Pane {
    var command = try OwnedCommand.init(gpa, launch);
    defer command.deinit();
    const pane_key = try panes.allocateKey();
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
        break :fresh created;
    };
    select.concurrent(.pane_output, readPane, .{ io, fresh }) catch |err| {
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

fn encodeFrame(
    io: Io,
    buffer: []u8,
    attachment: *Attachment,
    force_snapshot: bool,
    metrics: *RuntimeMetrics,
) !?[]const u8 {
    const pane = attachment.pane;
    const started = diagnostics.now(io);
    if (pane.dirty) try pane.render(false);
    var span_storage: [schema.frame.max_span_count]schema.frame.Span = undefined;
    var snapshot = force_snapshot;
    const diff = if (snapshot)
        damage.Diff{}
    else
        damage.collectSpans(
            pane.screen.cells,
            attachment.acknowledged.cells,
            pane.screen.w,
            pane.damaged_rows,
            &span_storage,
        );
    var span_count = diff.span_count;
    snapshot = snapshot or diff.snapshot_required;

    const cursor_changed = !std.meta.eql(pane.cursor, attachment.acknowledged_cursor);
    const mouse_changed = !std.meta.eql(pane.mouse, attachment.acknowledged_mouse);
    const input_modes_changed = !std.meta.eql(
        pane.input_modes,
        attachment.acknowledged_input_modes,
    );
    if (!snapshot and span_count == 0 and !cursor_changed and !mouse_changed and
        !input_modes_changed)
    {
        @memset(pane.damaged_rows, false);
        pane.dirty = false;
        if (comptime diagnostics.enabled) {
            metrics.noop_frames += 1;
            metrics.damaged_rows += diff.damaged_rows;
            metrics.diff_scanned_cells += diff.scanned_cells;
            metrics.coalesced_spans += diff.coalesced_spans;
            metrics.bridged_cells += diff.bridged_cells;
            metrics.coalesced_bytes_saved += diff.bytes_saved;
            metrics.encode.observe(diagnostics.elapsed(started, diagnostics.now(io)));
        }
        return null;
    }
    if (snapshot) {
        span_storage[0] = .{ .start = 0, .cells = pane.screen.cells };
        span_count = 1;
    }

    const frame_id = attachment.next_frame_id;
    attachment.next_frame_id += 1;
    const payload = try schema.encodePaneFrame(buffer, .{
        .pane_id = pane.id,
        .frame_id = frame_id,
        .base_frame_id = if (snapshot) 0 else attachment.acknowledged_frame_id,
        .cols = pane.screen.w,
        .rows = pane.screen.h,
        .cursor = pane.cursor,
        .mouse = pane.mouse,
        .input_modes = pane.input_modes,
        .spans = span_storage[0..span_count],
    });
    if (snapshot) {
        @memcpy(attachment.acknowledged.cells, pane.screen.cells);
    } else {
        for (span_storage[0..span_count]) |span| {
            const start: usize = @intCast(span.start);
            @memcpy(attachment.acknowledged.cells[start..][0..span.cells.len], span.cells);
        }
    }
    attachment.acknowledged_cursor = pane.cursor;
    attachment.acknowledged_mouse = pane.mouse;
    attachment.acknowledged_input_modes = pane.input_modes;
    attachment.outstanding_frame_id = frame_id;
    attachment.frame_sent_ns = diagnostics.now(io);
    @memset(pane.damaged_rows, false);
    pane.dirty = false;
    if (comptime diagnostics.enabled) {
        var cell_count: u64 = 0;
        for (span_storage[0..span_count]) |span| cell_count += span.cells.len;
        metrics.frames += 1;
        metrics.frame_bytes += payload.len;
        metrics.frame_cells += cell_count;
        metrics.frame_spans += span_count;
        if (snapshot) metrics.snapshots += 1;
        if (!snapshot and span_count == 0) metrics.cursor_only_frames += 1;
        metrics.damaged_rows += diff.damaged_rows;
        metrics.diff_scanned_cells += diff.scanned_cells;
        if (!snapshot) {
            metrics.coalesced_spans += diff.coalesced_spans;
            metrics.bridged_cells += diff.bridged_cells;
            metrics.coalesced_bytes_saved += diff.bytes_saved;
        }
        metrics.encode.observe(diagnostics.elapsed(started, diagnostics.now(io)));
    }
    return payload;
}

/// Encodes one queued response against the *current* stores. A response can
/// outlive what it describes - the workspace of a queued snapshot may close
/// before the send slot frees up - and encoding must then degrade to a
/// `request_failed` reply, never to an error that tears the client down.
fn encodeResponse(
    buffer: []u8,
    response: *PendingResponse,
    panes: *PaneStore,
    workspaces: *WorkspaceStore,
    history_result: *?*history.model.QueryResult,
) ![]const u8 {
    var descriptor_storage: [max_panes]schema.PaneDescriptor = undefined;
    var tab_storage: [max_tabs_per_workspace]schema.TabDescriptor = undefined;
    var history_storage: [history.model.max_results]schema.HistoryEntry = undefined;
    return switch (response.*) {
        .request_failed => |failure| try schema.encodeRequestFailed(buffer, .{
            .request_id = failure.request_id,
            .code = failure.code,
            .message = failure.message,
        }),
        .pane_opened => |opened| try schema.encodePaneOpened(buffer, opened),
        .tab_snapshot => |snapshot| try schema.encodeTabSnapshot(buffer, .{
            .request_id = snapshot.request_id,
            .location = snapshot.location,
            .panes = panes.descriptorsAt(snapshot.location, &descriptor_storage),
        }),
        .workspace_snapshot => |snapshot| payload: {
            const tabs = workspaces.descriptors(snapshot.workspace, panes, &tab_storage) orelse
                break :payload try schema.encodeRequestFailed(buffer, .{
                    .request_id = snapshot.request_id,
                    .code = .workspace_not_found,
                    .message = "workspace closed before its snapshot was sent",
                });
            break :payload try schema.encodeWorkspaceSnapshot(buffer, .{
                .request_id = snapshot.request_id,
                .workspace = snapshot.workspace,
                .tabs = tabs,
            });
        },
        .tab_created => |*created| try schema.encodeTabCreated(buffer, .{
            .request_id = created.request_id,
            .location = created.location,
            .position = created.position,
            .label = created.labelSlice(),
            .root_pane_id = created.root_pane_id,
        }),
        .tab_renamed => |*renamed| try schema.encodeTabRenamed(buffer, .{
            .request_id = renamed.request_id,
            .location = renamed.location,
            .label = renamed.labelSlice(),
        }),
        .tab_closed => |closed| try schema.encodeTabClosed(buffer, closed),
        .tab_moved => |moved| try schema.encodeTabMoved(buffer, moved),
        .history_result => |result| payload: {
            history_result.* = result;
            break :payload try encodeHistoryResult(buffer, result, &history_storage);
        },
    };
}

fn encodeHistoryResult(
    buffer: []u8,
    result: *const history.model.QueryResult,
    storage: *[history.model.max_results]schema.HistoryEntry,
) ![]const u8 {
    std.debug.assert(result.entries.len <= storage.len);
    for (result.entries, 0..) |entry, index| {
        storage[index] = .{
            .id = entry.id,
            .pane_id = entry.pane_id,
            .started_at_ms = entry.started_at_ms,
            .duration_ns = entry.duration_ns,
            .exit_code = entry.exit_code,
            .status = switch (entry.status) {
                .completed => .completed,
                .interrupted => .interrupted,
            },
            .command = entry.command,
            .cwd = entry.cwd,
            .workspace_path = entry.workspace_path,
        };
    }
    return schema.encodeHistoryResults(buffer, .{
        .request_id = result.request_id,
        .entries = storage[0..result.entries.len],
    });
}

fn startSend(
    io: Io,
    select: *Io.Select(RuntimeEvent),
    connection: *core.transport.SocketChannel,
    payload: []const u8,
    send_pending: *bool,
) !void {
    std.debug.assert(!send_pending.*);
    send_pending.* = true;
    select.concurrent(.client_sent, sendClient, .{ io, connection, payload }) catch |err| {
        send_pending.* = false;
        return err;
    };
}

fn sendClient(
    io: Io,
    connection: *core.transport.SocketChannel,
    payload: []const u8,
) anyerror!void {
    try connection.send(io, payload);
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

fn acceptClient(io: Io, listener: *transport.local.LocalListener) anyerror!core.transport.SocketChannel {
    return listener.accept(io);
}

fn handshakeClient(io: Io, connection: *core.transport.SocketChannel) anyerror!void {
    const response = try transport.handshake.perform(io, connection);
    if (response == .rejected) return error.IncompatibleProtocol;
}

fn receiveClient(
    io: Io,
    connection: *core.transport.SocketChannel,
    buffer: []u8,
) anyerror![]u8 {
    return connection.receive(io, buffer);
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
    stats.history_input_bytes = pane.processHistoryInput(&stats);
    stats.elapsed_ns = pane.ingest(io, pane.output_buffer[0..output_len], &stats) catch |err|
        return .{ .pane = pane.key(), .result = err };
    return .{ .pane = pane.key(), .result = stats };
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
