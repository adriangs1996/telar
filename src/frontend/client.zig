//! Disposable multi-pane client for Telar's current schema.

const std = @import("std");
const core = @import("telar-core");
const action_mod = @import("action.zig");
const client_outbox = @import("client_outbox.zig");
const client_requests = @import("client_requests.zig");
const client_telemetry = @import("client_telemetry.zig");
const client_view = @import("client_ui.zig");
const default_bindings = @import("default_bindings.zig");
const input_mod = @import("input.zig");
const keybind = @import("keybind.zig");
const kitty = @import("kitty.zig");
const layout_mod = @import("layout.zig");
const lua_config = @import("lua_config.zig");
const multiplexer = @import("multiplexer.zig");
const mouse_protocol = @import("mouse_protocol.zig");
const pace = @import("pace.zig");
const platform = @import("platform.zig");
const plugin_broker = @import("plugin_broker.zig");
const term = @import("term.zig");
const tabs_mod = @import("tabs.zig");
const theme = @import("theme.zig");

const Io = std.Io;
const File = Io.File;
const schema = core.schema;
const diagnostics = core.diagnostics;
const ui = core.ui;

const input_chunk_size = 4096;
const max_bindings = 256;
const max_binding_keys = default_bindings.max_keys;
const held_binding_bytes = 128;
const default_binding_count = default_bindings.count;

pub const Action = action_mod.Action;

pub const ConfiguredBinding = keybind.Binding(Action, max_binding_keys);
const InputRouter = keybind.Router(
    Action,
    max_bindings,
    max_binding_keys,
    input_chunk_size,
    held_binding_bytes,
);

comptime {
    std.debug.assert(input_chunk_size <= client_outbox.max_input_bytes);
    std.debug.assert(lua_config.max_expression_paste_bytes + 16 <= client_outbox.max_input_bytes);
}

pub const Options = struct {
    arguments: []const []const u8,
    cwd: []const u8,
    endpoint: []const u8,
    bindings: []const ConfiguredBinding = &.{},
    bindings_configured: bool = false,
    theme: theme.Theme = theme.default_theme,
    sidebar_rendering: kitty.SidebarRendering = .automatic,
    sidebar_visible: bool = true,
    host_shared_memory: bool = false,
    input_escape_timeout_ns: u64 = keybind.default_escape_timeout_ns,
    input_sequence_timeout_ns: u64 = keybind.default_sequence_timeout_ns,
    lua_generation: ?*lua_config.Generation = null,
    config_path: ?[]const u8 = null,
    config_mtime_ns: i128 = 0,
    theme_locked: bool = false,
    sidebar_renderer_locked: bool = false,
    plugin_registry: ?*plugin_broker.Registry = null,
    trust_store: ?*core.plugin.TrustStore = null,
    trust_path: ?[]const u8 = null,
    profile: ?[]const u8 = null,
};

const ClientMetrics = client_telemetry.Metrics;
const encodeSgrMouse = mouse_protocol.encodeSgr;
const mouseTracked = mouse_protocol.tracked;

const InputChunk = struct {
    bytes: [input_chunk_size]u8 = undefined,
    len: u16 = 0,

    fn slice(chunk: *const InputChunk) []const u8 {
        return chunk.bytes[0..chunk.len];
    }
};

const ClientEvent = union(enum) {
    input: anyerror!InputChunk,
    input_timeout: anyerror!void,
    binding_timeout: anyerror!void,
    capability_timeout: anyerror!void,
    resized: anyerror!void,
    server: anyerror![]u8,
    sent: anyerror!void,
    draw: anyerror!void,
    telemetry_tick: anyerror!void,
    telemetry_written: anyerror!void,
    config_reload: anyerror!ConfigReload,
    plugin_result: anyerror!plugin_broker.WorkerResult,
};

const ConfigReload = union(enum) {
    unchanged: i128,
    loaded: struct {
        generation: *lua_config.Generation,
        registry: *plugin_broker.Registry,
        trust_store: *core.plugin.TrustStore,
        mtime_ns: i128,
    },
    failed: struct {
        diagnostic: lua_config.Diagnostic,
        mtime_ns: i128,
    },
};

/// The request that opens the first pane; everything else is numbered by
/// `Client.nextId`.
const initial_request_id: schema.RequestId = @enumFromInt(1);

/// One attached client: the long-lived objects `run` owns by pointer, plus
/// every piece of pending-request and frame-pacing state that used to be a
/// loose local threaded through fourteen-argument calls.
const Client = struct {
    io: Io,
    gpa: std.mem.Allocator,
    connection: *core.transport.SocketChannel,
    send_buffer: []u8,
    outbox: *client_outbox.Outbox,
    writer: *Io.Writer,
    select: *Io.Select(ClientEvent),
    options: *const Options,
    metrics: *ClientMetrics,
    screen: *term.Screen,
    view: *client_view.State,
    tabs: *tabs_mod.Model,
    graphics_store: *kitty.Store,
    capabilities: *kitty.TerminalCapabilities,
    input_file: File,
    lua_generation: *?*lua_config.Generation,
    config_diagnostic: lua_config.Diagnostic = .{},
    plugin_registry: *?*plugin_broker.Registry,
    trust_store: *?*core.plugin.TrustStore,
    sidebar_rendering: kitty.SidebarRendering,
    config_mtime_ns: i128,
    next_config_generation: u64 = 2,
    plugin_pending: bool = false,
    paste_pane: ?schema.PaneId = null,

    input_read_pending: bool = false,
    next_request_id: u64 = 2,
    requests: client_requests.Tracker = .{},
    pacer: pace.Pacer = .{},
    draw_pending: bool = false,
    draw_due_ns: u64 = 0,
    pending_updates: usize = 0,
    last_presented_ns: ?u64 = null,

    fn nextId(client: *Client) !schema.RequestId {
        return nextRequestId(&client.next_request_id);
    }

    fn enqueue(client: *Client, message: client_outbox.Message) !void {
        try client.outbox.push(message);
        try client.pumpOutbox();
    }

    fn enqueueInput(client: *Client, pane_id: schema.PaneId, bytes: []const u8) !void {
        try client.outbox.pushInput(pane_id, bytes);
        try client.pumpOutbox();
    }

    fn enqueueRename(client: *Client, rename: schema.RenameTab) !void {
        try client.outbox.pushRename(rename);
        try client.pumpOutbox();
    }

    fn enqueueRequest(
        client: *Client,
        request_id: schema.RequestId,
        continuation: client_requests.Continuation,
        message: client_outbox.Message,
    ) !void {
        try client.requests.add(request_id, continuation);
        errdefer _ = client.requests.take(request_id);
        try client.enqueue(message);
    }

    fn enqueueRenameRequest(
        client: *Client,
        rename: schema.RenameTab,
        continuation: client_requests.Continuation,
    ) !void {
        try client.requests.add(rename.request_id, continuation);
        errdefer _ = client.requests.take(rename.request_id);
        try client.enqueueRename(rename);
    }

    fn pumpOutbox(client: *Client) !void {
        if (client.outbox.send_pending or client.outbox.len == 0) return;
        const payload = try client.outbox.encodeNext(client.send_buffer);
        client.outbox.send_pending = true;
        client.select.concurrent(.sent, sendClient, .{
            client.io,
            client.connection,
            payload,
        }) catch |err| {
            client.outbox.send_pending = false;
            return err;
        };
    }

    fn returnGraphicsCredits(client: *Client) !void {
        while (client.graphics_store.peekCredit()) |credit| {
            client.outbox.push(.{ .graphics_credit = .{
                .pane_id = credit.pane_id,
                .bytes = @intCast(credit.bytes),
            } }) catch break;
            client.graphics_store.consumeCredit(credit);
        }
        try client.pumpOutbox();
    }

    fn scheduleInputRead(client: *Client) !void {
        if (client.input_read_pending or !client.outbox.canQueueInput()) return;
        try client.select.concurrent(.input, readInput, .{ client.io, client.input_file });
        client.input_read_pending = true;
    }

    fn requestDraw(client: *Client) !void {
        client.pending_updates += 1;
        if (comptime diagnostics.enabled)
            client.metrics.max_pending_updates = @max(client.metrics.max_pending_updates, client.pending_updates);
        if (client.draw_pending) return;
        const now_ns = monotonic(client.io);
        const deadline_ns = client.pacer.waitUntil(now_ns) orelse now_ns;
        if (deadline_ns != now_ns) client.pacer.noteThrottled();
        client.draw_pending = true;
        client.draw_due_ns = deadline_ns;
        client.select.concurrent(.draw, waitToDraw, .{ client.io, deadline_ns }) catch |err| {
            client.draw_pending = false;
            return err;
        };
    }

    /// Routes one decoded server message. Returns an exit status when the
    /// message ends the session, null to keep running.
    fn handleServer(client: *Client, message: schema.ServerMessage) !?u8 {
        switch (message) {
            .pane_opened => |opened| try client.handlePaneOpened(opened),
            .tab_snapshot => |snapshot| try client.handleTabSnapshot(snapshot),
            .workspace_snapshot => |snapshot| try client.handleWorkspaceSnapshot(snapshot),
            .tab_created => |created| try client.handleTabCreated(created),
            .tab_renamed => |renamed| try client.handleTabRenamed(renamed),
            .tab_closed => |closed| return client.handleTabClosed(closed),
            .tab_moved => |moved| try client.handleTabMoved(moved),
            .pane_frame => |frame| try client.handlePaneFrame(frame),
            .pane_exited => |exited| try client.handlePaneExited(exited),
            .request_failed => |failure| try client.handleRequestFailed(failure),
            .resync_required => |required| {
                if (required.workspace_closed) return 0;
                try client.handleResyncRequired(required);
            },
            .runtime_stopping => return 0,
            .history_results => return error.UnexpectedHistoryResults,
            .graphics_snapshot,
            .graphics_image,
            .graphics_shared_image,
            .graphics_image_chunk,
            .graphics_placement,
            .graphics_delete_image,
            .graphics_delete_placement,
            => try client.handleGraphics(message),
        }
        return null;
    }

    fn handlePaneOpened(client: *Client, opened: schema.PaneOpened) !void {
        const continuation = client.requests.take(opened.request_id) orelse
            return error.UnexpectedRequest;
        switch (continuation) {
            .initial_open => {
                if (client.tabs.count != 0) return error.UnexpectedRequest;
                try client.tabs.bootstrap(
                    opened.pane_id,
                    opened.location,
                    rectSize(client.view.workbench()) orelse return error.TerminalTooSmall,
                );
                client.view.invalidate();
                try client.scheduleInputRead();
                const workspace_request_id = try client.nextId();
                try client.enqueueRequest(
                    workspace_request_id,
                    .{ .workspace_snapshot = opened.location.workspace },
                    .{ .request_workspace_snapshot = .{
                        .request_id = workspace_request_id,
                        .workspace = opened.location.workspace,
                    } },
                );
                const tab_request_id = try client.nextId();
                try client.enqueueRequest(
                    tab_request_id,
                    .{ .tab_snapshot = opened.location },
                    .{ .request_tab_snapshot = .{
                        .request_id = tab_request_id,
                        .location = opened.location,
                    } },
                );
            },
            .split => |split| {
                if (!std.meta.eql(split.location, opened.location))
                    return error.UnexpectedPane;
                const tab = client.tabs.tabForPane(split.target_pane) orelse
                    return error.UnexpectedPane;
                const model = &tab.model;
                if (model.find(split.target_pane) != null) {
                    try model.split(split.target_pane, opened.pane_id, opened.location, split.axis, client.view.workbench());
                } else {
                    try model.addDiscovered(opened.pane_id, opened.location, client.view.workbench());
                    try model.markAttached(opened.pane_id);
                }
                client.view.invalidate();
                try client.resizeAttached(model, client.view.workbench());
            },
            .attach_pane => |attachment| {
                if (attachment.pane_id != opened.pane_id or
                    !std.meta.eql(attachment.location, opened.location))
                    return error.UnexpectedPane;
                const pane = client.tabs.findPane(opened.pane_id) orelse
                    return error.UnexpectedPane;
                pane.attached = true;
            },
            else => return error.UnexpectedRequest,
        }
        try client.requestDraw();
    }

    fn handleTabSnapshot(client: *Client, snapshot: schema.TabSnapshotView) !void {
        const continuation = client.requests.take(snapshot.request_id) orelse
            return error.UnexpectedTabSnapshot;
        if (continuation != .tab_snapshot or
            !std.meta.eql(continuation.tab_snapshot, snapshot.location))
            return error.UnexpectedTabSnapshot;
        const tab = try client.tabs.reconcileTab(snapshot, client.view.workbench());
        const model = &tab.model;
        client.view.invalidate();
        try client.resizeAttached(model, client.view.workbench());
        for (&model.panes) |*slot| {
            const pane = if (slot.*) |*value| value else continue;
            if (pane.attached) continue;
            const size = model.contentSize(pane.id, client.view.workbench()) orelse
                return error.PaneTooSmall;
            const request_id = try client.nextId();
            try client.enqueueRequest(
                request_id,
                .{ .attach_pane = .{
                    .pane_id = pane.id,
                    .location = snapshot.location,
                } },
                .{ .open_pane = .{
                    .request_id = request_id,
                    .target = .{ .pane = pane.id },
                    .size = size,
                    .launch = null,
                } },
            );
        }
        try client.requestDraw();
    }

    fn handleWorkspaceSnapshot(client: *Client, snapshot: schema.WorkspaceSnapshotView) !void {
        const continuation = client.requests.take(snapshot.request_id) orelse
            return error.UnexpectedWorkspaceSnapshot;
        if (continuation != .workspace_snapshot or
            !std.meta.eql(continuation.workspace_snapshot, snapshot.workspace))
            return error.UnexpectedWorkspaceSnapshot;
        var canonical_tabs: [tabs_mod.max_tabs]schema.TabId = undefined;
        var canonical_count: usize = 0;
        var iterator = snapshot.tabs();
        while (try iterator.next()) |descriptor| {
            canonical_tabs[canonical_count] = descriptor.tab_id;
            canonical_count += 1;
        }
        for (client.tabs.items[0..client.tabs.count]) |*slot| {
            const tab = if (slot.*) |*value| value else continue;
            if (std.mem.findScalar(
                schema.TabId,
                canonical_tabs[0..canonical_count],
                tab.location.tab_id,
            ) == null) releaseTabGraphics(client.graphics_store, tab);
        }
        try client.tabs.reconcileWorkspace(snapshot);
        if (!client.requests.has(.tab_snapshot)) {
            if (client.tabs.active()) |active| {
                if (!active.snapshot_loaded) {
                    const request_id = try client.nextId();
                    try client.enqueueRequest(
                        request_id,
                        .{ .tab_snapshot = active.location },
                        .{ .request_tab_snapshot = .{
                            .request_id = request_id,
                            .location = active.location,
                        } },
                    );
                }
            }
        }
        client.view.invalidate();
        try client.requestDraw();
    }

    fn handleTabCreated(client: *Client, created: schema.TabCreated) !void {
        const continuation = client.requests.take(created.request_id) orelse
            return error.UnexpectedTabCreated;
        if (continuation != .create_tab or
            !std.meta.eql(continuation.create_tab, created.location.workspace))
            return error.UnexpectedTabCreated;
        if (client.tabs.active()) |current| {
            var handler: InputHandler = .{ .client = client };
            try handler.detachTab(current);
        }
        _ = try client.tabs.addCreated(
            created,
            rectSize(client.view.workbench()) orelse return error.TerminalTooSmall,
        );
        client.view.invalidate();
        try client.requestDraw();
    }

    fn handleTabRenamed(client: *Client, renamed: schema.TabRenamed) !void {
        const continuation = client.requests.take(renamed.request_id) orelse
            return error.UnexpectedTabRenamed;
        if (continuation != .rename_tab or
            !std.meta.eql(continuation.rename_tab, renamed.location))
            return error.UnexpectedTabRenamed;
        if (!client.tabs.rename(renamed.location.tab_id, renamed.label))
            return error.UnexpectedTab;
        client.view.invalidate();
        try client.requestDraw();
    }

    fn handleTabClosed(client: *Client, closed: schema.TabClosed) !?u8 {
        const lifecycle_event = closed.request_id == .none;
        if (lifecycle_event) {
            client.requests.ignoreTab(closed.location.tab_id);
        } else {
            const continuation = client.requests.take(closed.request_id) orelse
                return error.UnexpectedTabClosed;
            if (continuation != .close_tab or
                !std.meta.eql(continuation.close_tab, closed.location))
                return error.UnexpectedTabClosed;
        }
        const was_active = client.tabs.activeConst() != null and
            client.tabs.activeConst().?.location.tab_id == closed.location.tab_id;
        // The runtime sends no per-pane exit for a closed tab, so its
        // graphics would stay resident forever without this.
        if (client.tabs.find(closed.location.tab_id)) |closing|
            releaseTabGraphics(client.graphics_store, closing);
        if (!client.tabs.remove(closed.location.tab_id)) {
            if (lifecycle_event) return null;
            return error.UnexpectedTab;
        }
        if (closed.workspace_closed or client.tabs.count == 0) return 0;
        if (was_active) {
            const active = client.tabs.active().?;
            const request_id = try client.nextId();
            try client.enqueueRequest(
                request_id,
                .{ .tab_snapshot = active.location },
                .{ .request_tab_snapshot = .{
                    .request_id = request_id,
                    .location = active.location,
                } },
            );
        }
        client.view.invalidate();
        try client.requestDraw();
        return null;
    }

    fn handleTabMoved(client: *Client, moved: schema.TabMoved) !void {
        const continuation = client.requests.take(moved.request_id) orelse
            return error.UnexpectedTabMoved;
        if (continuation != .move_tab or
            !std.meta.eql(continuation.move_tab, moved.location))
            return error.UnexpectedTabMoved;
        _ = client.tabs.move(moved.location.tab_id, moved.position);
        client.view.invalidate();
        try client.requestDraw();
    }

    fn handlePaneFrame(client: *Client, frame: schema.frame.FrameView) !void {
        const pane = client.tabs.findPane(frame.pane_id) orelse return error.UnexpectedPane;
        if (!pane.attached) return;
        if (frame.base_frame_id != 0 and
            frame.base_frame_id != pane.applied_frame_id)
        {
            try client.enqueue(.{ .request_snapshot = .{
                .pane_id = frame.pane_id,
                .known_frame_id = pane.applied_frame_id,
            } });
            return;
        }
        const apply_started = diagnostics.now(client.io);
        const tab = client.tabs.tabForPane(frame.pane_id) orelse
            return error.UnexpectedPane;
        const applied = try tab.model.applyFrame(frame);
        if (comptime diagnostics.enabled) {
            client.metrics.frames += 1;
            client.metrics.frame_cells += applied.cells;
            client.metrics.frame_spans += applied.spans;
            if (frame.base_frame_id == 0) client.metrics.snapshots += 1;
            client.metrics.apply.observe(diagnostics.elapsed(apply_started, diagnostics.now(client.io)));
        }
        try client.requestDraw();
    }

    fn handlePaneExited(client: *Client, exited: schema.PaneExited) !void {
        client.graphics_store.clearPane(exited.pane_id);
        const tab = client.tabs.tabForPane(exited.pane_id);
        if (tab) |value| _ = value.model.removePane(exited.pane_id);
        client.view.invalidate();
        _ = client.requests.completePaneClose(exited.pane_id);
        if (client.tabs.active()) |active| {
            if (active.model.pane_count != 0)
                try client.resizeAttached(&active.model, client.view.workbench());
        }
        try client.requestDraw();
    }

    fn handleRequestFailed(client: *Client, failure: schema.RequestFailed) !void {
        const continuation = client.requests.take(failure.request_id) orelse {
            std.debug.print("telar runtime: {s}\n", .{failure.message});
            return error.UnexpectedRequestFailure;
        };
        switch (continuation) {
            .ignored, .close_pane, .rename_tab, .move_tab => {},
            .split => {
                if (client.tabs.active()) |active|
                    try client.resizeAttached(&active.model, client.view.workbench());
            },
            .attach_pane => |attachment| {
                if (client.tabs.tabForPane(attachment.pane_id)) |tab|
                    _ = tab.model.removePane(attachment.pane_id);
                client.view.invalidate();
                if (client.tabs.active()) |active|
                    try client.resizeAttached(&active.model, client.view.workbench());
            },
            .close_tab => {
                const active = client.tabs.active().?;
                const request_id = try client.nextId();
                try client.enqueueRequest(
                    request_id,
                    .{ .tab_snapshot = active.location },
                    .{ .request_tab_snapshot = .{
                        .request_id = request_id,
                        .location = active.location,
                    } },
                );
            },
            .initial_open, .workspace_snapshot, .tab_snapshot, .create_tab => {
                std.debug.print("telar runtime: {s}\n", .{failure.message});
                return error.RuntimeRequestFailed;
            },
        }
        try client.requestDraw();
    }

    fn handleResyncRequired(client: *Client, required: schema.ResyncRequired) !void {
        const workspace = client.tabs.workspace orelse return error.UnexpectedResync;
        if (!std.meta.eql(workspace, required.workspace)) return error.UnexpectedResync;
        if (client.requests.has(.workspace_snapshot)) return;
        const request_id = try client.nextId();
        try client.enqueueRequest(
            request_id,
            .{ .workspace_snapshot = workspace },
            .{ .request_workspace_snapshot = .{
                .request_id = request_id,
                .workspace = workspace,
            } },
        );
    }

    fn handleGraphics(client: *Client, message: schema.ServerMessage) !void {
        switch (message) {
            .graphics_snapshot => |snapshot| client.graphics_store.applySnapshot(snapshot) catch |err| switch (err) {
                error.GraphicsResyncRequired => try client.requestGraphicsSnapshot(snapshot.pane_id),
                else => return err,
            },
            .graphics_image => |image| {
                client.graphics_store.applyImage(image) catch |err| switch (err) {
                    error.GraphicsResyncRequired => try client.requestGraphicsSnapshot(image.pane_id),
                    else => return err,
                };
                if (client.tabs.tabForPane(image.pane_id)) |tab|
                    tab.model.setGraphicsPlaceholder(image.pane_id, client.capabilities.kitty_graphics != .supported);
            },
            .graphics_shared_image => |image| {
                client.graphics_store.applySharedImage(image) catch |err| switch (err) {
                    error.GraphicsResyncRequired => try client.requestGraphicsSnapshot(image.pane_id),
                    // The mapping should never fail on the machine this
                    // client declared it shares with the runtime. If it does,
                    // renegotiate down to pixel chunks and resynchronize
                    // instead of dying over one image.
                    error.GraphicsSharedMappingFailed => {
                        try client.enqueue(.{ .configure_graphics = .{ .shared = false } });
                        try client.requestGraphicsSnapshot(image.pane_id);
                    },
                    else => return err,
                };
                if (client.tabs.tabForPane(image.pane_id)) |tab|
                    tab.model.setGraphicsPlaceholder(image.pane_id, client.capabilities.kitty_graphics != .supported);
            },
            .graphics_image_chunk => |chunk| client.graphics_store.applyChunk(chunk) catch |err| switch (err) {
                error.GraphicsResyncRequired => try client.requestGraphicsSnapshot(chunk.pane_id),
                else => return err,
            },
            .graphics_placement => |placement| client.graphics_store.applyPlacement(placement) catch |err| switch (err) {
                error.GraphicsResyncRequired => try client.requestGraphicsSnapshot(placement.pane_id),
                else => return err,
            },
            .graphics_delete_image => |deleted| {
                client.graphics_store.deleteImage(deleted) catch |err| switch (err) {
                    error.GraphicsResyncRequired => try client.requestGraphicsSnapshot(deleted.pane_id),
                    else => return err,
                };
                if (client.tabs.tabForPane(deleted.pane_id)) |tab|
                    tab.model.setGraphicsPlaceholder(deleted.pane_id, client.capabilities.kitty_graphics != .supported and
                        client.graphics_store.hasPaneGraphics(deleted.pane_id));
            },
            .graphics_delete_placement => |deleted| client.graphics_store.deletePlacement(deleted) catch |err| switch (err) {
                error.GraphicsResyncRequired => try client.requestGraphicsSnapshot(deleted.pane_id),
                else => return err,
            },
            else => unreachable,
        }
        try client.requestDraw();
    }

    fn requestGraphicsSnapshot(client: *Client, pane_id: schema.PaneId) !void {
        try client.enqueue(.{ .request_graphics_snapshot = .{
            .pane_id = pane_id,
        } });
    }

    /// The `.draw` event: present if there is anything to show yet.
    fn presentDue(client: *Client) !void {
        client.draw_pending = false;
        if (comptime diagnostics.enabled)
            client.metrics.draw_lateness.observe(monotonic(client.io) -| client.draw_due_ns);
        if (client.pending_updates == 0) return;
        // A draw can be scheduled before the first `pane_opened` bootstraps a
        // tab - a resize or the capability timeout does exactly that. The
        // updates stay queued for the draw that follows the bootstrap.
        const model = presentableModel(client.tabs) orelse return;
        const presented_ns = try client.present(model);
        client.observePresentation(presented_ns);
        client.pacer.record(presented_ns, client.draw_due_ns, client.pending_updates);
        client.pending_updates = 0;
        // The graphics budget may have left work behind; the pacer turns
        // this into the next frame, not a spin.
        if (client.graphics_store.damage and client.capabilities.kitty_graphics == .supported)
            try client.requestDraw();
    }

    fn observePresentation(client: *Client, presented_ns: u64) void {
        if (comptime diagnostics.enabled) {
            if (client.last_presented_ns) |previous|
                client.metrics.paced_interval.observe(presented_ns -| previous);
        }
        client.last_presented_ns = presented_ns;
    }

    fn present(client: *Client, model: *multiplexer.Model) !u64 {
        const compose_started = diagnostics.now(client.io);
        const composed = try model.renderThemed(client.screen, client.view.workbench(), client.view.palette());
        const chrome = try client.view.render(client.screen, client.tabs, model, composed.full);
        if (client.config_diagnostic.len != 0 and client.screen.back.h != 0) {
            const palette = client.view.palette();
            const banner: core.ui.Rect = .{
                .y = client.screen.back.h - 1,
                .w = client.screen.back.w,
                .h = 1,
            };
            const style: core.ui.Style = .{
                .fg = palette.text,
                .bg = palette.red,
                .flags = .{ .bold = true },
            };
            client.screen.back.fill(banner, " ", style);
            const prefix_width = client.screen.back.writeText(banner, 0, banner.y, "TELAR CONFIG  ", style);
            _ = client.screen.back.writeText(
                banner,
                prefix_width,
                banner.y,
                client.config_diagnostic.message(),
                style,
            );
        }
        if (comptime diagnostics.enabled) {
            client.metrics.composed_panes += composed.panes;
            client.metrics.composed_cells += composed.cells;
            client.metrics.composed_damage_cells += composed.damaged_cells;
            client.metrics.chrome_scanned_cells += chrome.scanned;
            client.metrics.chrome_damaged_cells += chrome.damaged;
            client.metrics.full_compositions += @intFromBool(composed.full);
            client.metrics.compose.observe(diagnostics.elapsed(compose_started, diagnostics.now(client.io)));
        }
        const cell_size = client.capabilities.cellSize(client.screen.back.w, client.screen.back.h);
        const layout_snapshot = model.layoutSnapshot(client.view.workbench());
        var graphics_writer: CombinedGraphicsWriter = .{
            .panes = .{
                .store = client.graphics_store,
                .layout_snapshot = layout_snapshot,
                .cell_width = cell_size.width,
                .cell_height = cell_size.height,
            },
            .sidebar = client.view.kittySidebar(),
            .metrics = client.metrics,
        };
        if (client.capabilities.kitty_graphics == .supported) client.screen.graphics = .{
            .context = &graphics_writer,
            .write = CombinedGraphicsWriter.writeOpaque,
        };
        try flushScreen(client.io, client.screen, client.writer, client.metrics);
        try client.returnGraphicsCredits();
        const presented_ns = monotonic(client.io);
        for (&model.panes) |*slot| {
            const pane = if (slot.*) |*value| value else continue;
            if (!pane.attached or pane.pending_frame_id == 0) continue;
            const ack_started = diagnostics.now(client.io);
            try client.enqueue(.{ .frame_ack = .{
                .pane_id = pane.id,
                .frame_id = pane.pending_frame_id,
            } });
            pane.pending_frame_id = 0;
            if (comptime diagnostics.enabled)
                client.metrics.ack_enqueue.observe(diagnostics.elapsed(ack_started, diagnostics.now(client.io)));
        }
        return presented_ns;
    }

    fn resizeAttached(client: *Client, model: *multiplexer.Model, area: ui.Rect) !void {
        for (&model.panes) |*slot| {
            const pane = if (slot.*) |*value| value else continue;
            if (!pane.attached) continue;
            const size = model.contentSize(pane.id, area) orelse continue;
            try client.enqueue(.{ .pane_resize = .{
                .pane_id = pane.id,
                .size = size,
            } });
        }
    }
};

pub fn run(
    init: std.process.Init,
    connection: *core.transport.SocketChannel,
    options: Options,
) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    var lua_generation = options.lua_generation;
    defer if (lua_generation) |generation| generation.deinit();
    var plugin_registry = options.plugin_registry;
    defer if (plugin_registry) |registry| gpa.destroy(registry);
    var trust_store = options.trust_store;
    defer if (trust_store) |store| gpa.destroy(store);

    var telemetry_suffix_buffer: [64]u8 = undefined;
    const telemetry_suffix = std.fmt.bufPrint(
        &telemetry_suffix_buffer,
        "client-{d}",
        .{std.c.getpid()},
    ) catch "client";
    var telemetry = diagnostics.Sink.init(io, options.endpoint, telemetry_suffix);
    defer telemetry.deinit(io);

    var tty = platform.Tty.open() catch |err| {
        std.debug.print("telar needs a terminal: {s}\n", .{@errorName(err)});
        return err;
    };
    defer tty.deinit();
    // A panic aborts without running these defers; the crash path puts the
    // terminal back on its own.
    platform.installCrashRestore(&tty);

    const input_file = tty.readHandle();
    var tty_file = tty.writeHandle();
    var output_buffer: [512 * 1024]u8 = undefined;
    var output_writer = tty_file.writer(io, &output_buffer);
    const writer = &output_writer.interface;

    try writer.writeAll(platform.enter_sequence);
    try writer.writeAll(kitty.capability_query);
    try writer.flush();
    defer {
        writer.writeAll(platform.leave_sequence) catch {};
        writer.flush() catch {};
    }

    var host_size = terminalSize(&tty);
    const host_platform_size = tty.size();
    var capabilities: kitty.TerminalCapabilities = .{
        .window_width_px = host_platform_size.width_px,
        .window_height_px = host_platform_size.height_px,
    };
    const initial_cell_size = capabilities.cellSize(host_size.cols, host_size.rows);
    host_size.cell_width_px = initial_cell_size.width;
    host_size.cell_height_px = initial_cell_size.height;
    var screen = try term.Screen.init(gpa, host_size.cols, host_size.rows);
    defer screen.deinit();
    var view = try client_view.State.initWithTheme(
        gpa,
        host_size.cols,
        host_size.rows,
        options.theme,
    );
    defer view.deinit();
    if (!options.sidebar_visible) view.toggleSidebar();
    try view.configureSidebar(
        options.sidebar_rendering,
        capabilities.kitty_graphics,
        initial_cell_size.width,
        initial_cell_size.height,
    );
    var tabs = tabs_mod.Model.init(gpa);
    defer tabs.deinit();
    var graphics_store = if (options.host_shared_memory)
        kitty.Store.initSharedMemory(gpa)
    else
        kitty.Store.init(gpa);
    defer graphics_store.deinit();

    var watcher = try platform.ResizeWatcher.init(&tty);
    defer watcher.deinit();

    const receive_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    defer gpa.free(receive_buffer);
    const send_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    defer gpa.free(send_buffer);

    // Declared before the first pane opens, so every attachment the runtime
    // creates for this session already knows whether it may hand this client
    // shared memory names instead of pixel chunks.
    const configure_payload = try schema.encodeConfigureGraphics(send_buffer, .{
        .shared = kitty.clientSupportsSharedMemory(),
    });
    try connection.send(io, configure_payload);

    const open_payload = try schema.encodeOpenPane(send_buffer, .{
        .request_id = initial_request_id,
        .size = rectSize(view.workbench()) orelse return error.TerminalTooSmall,
        .launch = .{
            .cwd = options.cwd,
            .arguments = options.arguments,
        },
    });
    try connection.send(io, open_payload);

    var reload_orphan: ?*lua_config.Generation = null;
    defer if (reload_orphan) |generation| generation.deinit();
    var reload_registry_orphan: ?*plugin_broker.Registry = null;
    defer if (reload_registry_orphan) |registry| gpa.destroy(registry);
    var reload_trust_orphan: ?*core.plugin.TrustStore = null;
    defer if (reload_trust_orphan) |store| gpa.destroy(store);
    const outbox = try gpa.create(client_outbox.Outbox);
    defer gpa.destroy(outbox);
    outbox.* = .{};
    var select_storage: [12]ClientEvent = undefined;
    var select = Io.Select(ClientEvent).init(io, &select_storage);
    defer select.cancelDiscard();
    try select.concurrent(.resized, waitResize, .{ io, &watcher });
    try select.concurrent(.server, receive, .{ io, connection, receive_buffer });
    try select.concurrent(.capability_timeout, waitCapabilityTimeout, .{io});
    if (comptime diagnostics.enabled) {
        if (telemetry.available())
            try select.concurrent(.telemetry_tick, diagnostics.waitForTick, .{io});
    }

    var defaults = try defaultBindings();
    const configured_bindings = if (options.bindings_configured)
        options.bindings
    else
        defaults[0..];
    var input_router = try InputRouter.init(configured_bindings);
    input_router.escape_timeout_ns = options.input_escape_timeout_ns;
    input_router.sequence_timeout_ns = options.input_sequence_timeout_ns;
    var input_timeout_pending = false;
    var binding_timeout_pending = false;
    var telemetry_buffer: [4096]u8 = undefined;
    var telemetry_write_pending = false;
    var metrics: ClientMetrics = .{ .started_ns = diagnostics.now(io) };
    var client: Client = .{
        .io = io,
        .gpa = gpa,
        .connection = connection,
        .send_buffer = send_buffer,
        .outbox = outbox,
        .writer = writer,
        .select = &select,
        .options = &options,
        .metrics = &metrics,
        .screen = &screen,
        .view = &view,
        .tabs = &tabs,
        .graphics_store = &graphics_store,
        .capabilities = &capabilities,
        .input_file = input_file,
        .lua_generation = &lua_generation,
        .plugin_registry = &plugin_registry,
        .trust_store = &trust_store,
        .sidebar_rendering = options.sidebar_rendering,
        .config_mtime_ns = options.config_mtime_ns,
    };
    try client.requests.add(initial_request_id, .initial_open);
    if (options.config_path) |path|
        try select.concurrent(.config_reload, waitConfigReload, .{
            io,
            gpa,
            path,
            client.config_mtime_ns,
            client.next_config_generation,
            options.profile,
            client.lua_generation.*.?,
            client.plugin_registry.*.?,
            options.trust_path.?,
            &reload_orphan,
            &reload_registry_orphan,
            &reload_trust_orphan,
        });

    while (true) switch (try select.await()) {
        .input => |result| {
            client.input_read_pending = false;
            const chunk = try result;
            if (chunk.len == 0) return 0;
            var handler: InputHandler = .{ .client = &client };
            if (try input_router.feed(chunk.slice(), monotonic(io), &handler) == .stop)
                return 0;
            if (handler.redraw) try client.requestDraw();
            try scheduleInputTimers(io, &select, &input_router, &input_timeout_pending, &binding_timeout_pending);
            try client.scheduleInputRead();
        },
        .input_timeout => |result| {
            try result;
            input_timeout_pending = false;
            var handler: InputHandler = .{ .client = &client };
            if (try input_router.expireInput(monotonic(io), &handler) == .stop) return 0;
            if (handler.redraw) try client.requestDraw();
            try scheduleInputTimers(io, &select, &input_router, &input_timeout_pending, &binding_timeout_pending);
        },
        .binding_timeout => |result| {
            try result;
            binding_timeout_pending = false;
            var handler: InputHandler = .{ .client = &client };
            if (try input_router.expireBinding(monotonic(io), &handler) == .stop) return 0;
            if (handler.redraw) try client.requestDraw();
            try scheduleInputTimers(io, &select, &input_router, &input_timeout_pending, &binding_timeout_pending);
        },
        .capability_timeout => |result| {
            try result;
            if (capabilities.expire()) {
                const cell_size = capabilities.cellSize(host_size.cols, host_size.rows);
                try view.configureSidebar(
                    client.sidebar_rendering,
                    capabilities.kitty_graphics,
                    cell_size.width,
                    cell_size.height,
                );
                for (tabs.items[0..tabs.count]) |*slot| {
                    const tab = if (slot.*) |*value| value else continue;
                    for (&tab.model.panes) |*pane_slot| {
                        const pane = if (pane_slot.*) |*value| value else continue;
                        tab.model.setGraphicsPlaceholder(pane.id, graphics_store.hasPaneGraphics(pane.id));
                    }
                }
                view.invalidate();
                try client.requestDraw();
            }
        },
        .resized => |result| {
            try result;
            host_size = terminalSize(&tty);
            const platform_size = tty.size();
            if (platform_size.width_px != 0) capabilities.window_width_px = platform_size.width_px;
            if (platform_size.height_px != 0) capabilities.window_height_px = platform_size.height_px;
            const cell_size = capabilities.cellSize(host_size.cols, host_size.rows);
            host_size.cell_width_px = cell_size.width;
            host_size.cell_height_px = cell_size.height;
            try view.configureSidebar(
                client.sidebar_rendering,
                capabilities.kitty_graphics,
                cell_size.width,
                cell_size.height,
            );
            try screen.resize(host_size.cols, host_size.rows);
            try view.resize(host_size.cols, host_size.rows);
            if (tabs.active()) |active| {
                active.model.setCellSize(cell_size.width, cell_size.height);
                graphics_store.invalidatePlacements();
                try client.resizeAttached(&active.model, view.workbench());
            }
            // Pixel dimensions are not guaranteed to be present in winsize,
            // and can change independently when the font or display scale
            // changes. Refresh both values without blocking the resize path.
            try writer.writeAll("\x1b[14t\x1b[16t");
            try writer.flush();
            try client.requestDraw();
            try select.concurrent(.resized, waitResize, .{ io, &watcher });
        },
        .server => |result| {
            const payload = try result;
            const decode_started = diagnostics.now(io);
            const message = try schema.decodeServer(payload);
            if (comptime diagnostics.enabled) {
                metrics.server_messages += 1;
                metrics.server_bytes += payload.len;
                switch (message) {
                    .graphics_snapshot,
                    .graphics_image,
                    .graphics_shared_image,
                    .graphics_image_chunk,
                    .graphics_placement,
                    .graphics_delete_image,
                    .graphics_delete_placement,
                    => {
                        metrics.graphics_messages += 1;
                        metrics.graphics_bytes += payload.len;
                    },
                    else => {},
                }
                metrics.decode.observe(diagnostics.elapsed(decode_started, diagnostics.now(io)));
            }
            if (try client.handleServer(message)) |status| return status;
            try client.returnGraphicsCredits();
            try select.concurrent(.server, receive, .{ io, connection, receive_buffer });
        },
        .sent => |result| {
            try result;
            client.outbox.popSent();
            try client.returnGraphicsCredits();
            try client.scheduleInputRead();
        },
        .draw => |result| {
            try result;
            try client.presentDue();
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
            // Ticks can fire before the first tab exists; report nothing.
            const active = tabs.active() orelse continue;
            const focused = active.model.layout.focused() orelse .invalid;
            const line = client_telemetry.format(
                &telemetry_buffer,
                io,
                &metrics,
                &client.pacer,
                .{
                    .theme_name = view.theme.base.canonicalName(),
                    .active_tab = active.location.tab_id,
                    .tab_count = tabs.count,
                    .focused_pane = focused,
                    .pane_count = active.model.pane_count,
                    .pending_updates = client.pending_updates,
                    .draw_pending = client.draw_pending,
                    .outbox = client.outbox,
                    .capabilities = &capabilities,
                    .sidebar_rendering = view.sidebar_rendering,
                },
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
        .config_reload => |result| {
            const reload = try result;
            switch (reload) {
                .unchanged => |mtime_ns| client.config_mtime_ns = mtime_ns,
                .failed => |failure| {
                    client.config_diagnostic = failure.diagnostic;
                    client.config_mtime_ns = failure.mtime_ns;
                    try client.requestDraw();
                },
                .loaded => |loaded| {
                    const snapshot = &loaded.generation.snapshot;
                    const requested_sidebar = if (options.sidebar_renderer_locked)
                        client.sidebar_rendering
                    else
                        snapshot.sidebar_rendering;
                    _ = requested_sidebar.resolve(capabilities.kitty_graphics) catch |err| {
                        client.config_diagnostic.set(
                            "reloaded sidebar renderer is unavailable: {s}",
                            .{@errorName(err)},
                        );
                        client.config_mtime_ns = loaded.mtime_ns;
                        reload_orphan = null;
                        reload_registry_orphan = null;
                        reload_trust_orphan = null;
                        loaded.generation.deinit();
                        gpa.destroy(loaded.registry);
                        gpa.destroy(loaded.trust_store);
                        try client.requestDraw();
                        if (options.config_path) |path|
                            try select.concurrent(.config_reload, waitConfigReload, .{
                                io,
                                gpa,
                                path,
                                client.config_mtime_ns,
                                client.next_config_generation,
                                options.profile,
                                client.lua_generation.*.?,
                                client.plugin_registry.*.?,
                                options.trust_path.?,
                                &reload_orphan,
                                &reload_registry_orphan,
                                &reload_trust_orphan,
                            });
                        continue;
                    };
                    const bindings = if (snapshot.bindings_configured)
                        snapshot.bindingSlice()
                    else
                        defaults[0..];
                    var replacement = InputRouter.init(bindings) catch |err| {
                        client.config_diagnostic.set(
                            "reloaded keymap is invalid: {s}",
                            .{@errorName(err)},
                        );
                        client.config_mtime_ns = loaded.mtime_ns;
                        reload_orphan = null;
                        reload_registry_orphan = null;
                        reload_trust_orphan = null;
                        loaded.generation.deinit();
                        gpa.destroy(loaded.registry);
                        gpa.destroy(loaded.trust_store);
                        try client.requestDraw();
                        if (options.config_path) |path|
                            try select.concurrent(.config_reload, waitConfigReload, .{
                                io,
                                gpa,
                                path,
                                client.config_mtime_ns,
                                client.next_config_generation,
                                options.profile,
                                client.lua_generation.*.?,
                                client.plugin_registry.*.?,
                                options.trust_path.?,
                                &reload_orphan,
                                &reload_registry_orphan,
                                &reload_trust_orphan,
                            });
                        continue;
                    };
                    replacement.escape_timeout_ns = snapshot.input_escape_timeout_ns;
                    replacement.sequence_timeout_ns = snapshot.input_sequence_timeout_ns;

                    input_router = replacement;
                    if (!options.theme_locked) view.setTheme(snapshot.theme);
                    client.sidebar_rendering = requested_sidebar;
                    view.setSidebarVisible(snapshot.sidebar_visible);
                    const cell_size = capabilities.cellSize(host_size.cols, host_size.rows);
                    try view.configureSidebar(
                        client.sidebar_rendering,
                        capabilities.kitty_graphics,
                        cell_size.width,
                        cell_size.height,
                    );
                    if (tabs.active()) |active|
                        try client.resizeAttached(&active.model, view.workbench());

                    const previous = client.lua_generation.*;
                    client.lua_generation.* = loaded.generation;
                    reload_orphan = null;
                    const previous_registry = client.plugin_registry.*;
                    client.plugin_registry.* = loaded.registry;
                    reload_registry_orphan = null;
                    const previous_trust = client.trust_store.*;
                    client.trust_store.* = loaded.trust_store;
                    reload_trust_orphan = null;
                    if (previous) |old| old.deinit();
                    if (previous_registry) |old| gpa.destroy(old);
                    if (previous_trust) |old| gpa.destroy(old);
                    client.config_mtime_ns = loaded.mtime_ns;
                    client.next_config_generation += 1;
                    client.config_diagnostic.len = 0;
                    try client.requestDraw();
                },
            }
            if (options.config_path) |path|
                try select.concurrent(.config_reload, waitConfigReload, .{
                    io,
                    gpa,
                    path,
                    client.config_mtime_ns,
                    client.next_config_generation,
                    options.profile,
                    client.lua_generation.*.?,
                    client.plugin_registry.*.?,
                    options.trust_path.?,
                    &reload_orphan,
                    &reload_registry_orphan,
                    &reload_trust_orphan,
                });
        },
        .plugin_result => |result| {
            client.plugin_pending = false;
            const worker_result = result catch |err| {
                client.config_diagnostic.set("plugin worker failed: {s}", .{@errorName(err)});
                try client.requestDraw();
                continue;
            };
            const registry = client.plugin_registry.* orelse {
                client.config_diagnostic.set("plugin registry changed while action was running", .{});
                try client.requestDraw();
                continue;
            };
            registry.authorizeBatch(
                worker_result.package_index,
                worker_result.plugin_id,
                worker_result.digest,
                &worker_result.batch,
            ) catch |err| {
                client.config_diagnostic.set("plugin effect denied: {s}", .{@errorName(err)});
                try client.requestDraw();
                continue;
            };
            client.config_diagnostic.len = 0;
            var handler: InputHandler = .{ .client = &client };
            for (worker_result.batch.slice()) |effect|
                if (try handler.applyNativeAction(effect) == .stop) return 0;
            if (handler.redraw) try client.requestDraw();
        },
    };
}

fn waitConfigReload(
    io: Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    known_mtime_ns: i128,
    generation_number: u64,
    profile: ?[]const u8,
    current_generation: *const lua_config.Generation,
    current_registry: *const plugin_broker.Registry,
    trust_path: []const u8,
    orphan: *?*lua_config.Generation,
    registry_orphan: *?*plugin_broker.Registry,
    trust_orphan: *?*core.plugin.TrustStore,
) anyerror!ConfigReload {
    try io.sleep(.fromSeconds(1), .awake);
    const mtime_ns = current_generation.watchFingerprint(io, path) ^
        @as(i128, current_registry.watchFingerprint(gpa, io)) ^
        @as(i128, trustWatchFingerprint(io, trust_path));
    if (mtime_ns == known_mtime_ns) return .{ .unchanged = mtime_ns };
    var diagnostic: lua_config.Diagnostic = .{};
    const generation = lua_config.Generation.loadFileProfile(
        gpa,
        io,
        path,
        generation_number,
        profile,
        &diagnostic,
    ) catch return .{ .failed = .{
        .diagnostic = diagnostic,
        .mtime_ns = mtime_ns,
    } };
    orphan.* = generation;
    const trust = loadReloadTrustStore(gpa, io, trust_path) catch |err| {
        orphan.* = null;
        generation.deinit();
        diagnostic.set("cannot load plugin trust store: {s}", .{@errorName(err)});
        return .{ .failed = .{ .diagnostic = diagnostic, .mtime_ns = mtime_ns } };
    };
    trust_orphan.* = trust;
    const registry = gpa.create(plugin_broker.Registry) catch {
        orphan.* = null;
        trust_orphan.* = null;
        generation.deinit();
        gpa.destroy(trust);
        diagnostic.set("cannot allocate reloaded plugin registry", .{});
        return .{ .failed = .{ .diagnostic = diagnostic, .mtime_ns = mtime_ns } };
    };
    registry.* = plugin_broker.Registry.loadWithTrust(
        gpa,
        io,
        generation.configDir(),
        generation.pluginSlice(),
        trust,
    ) catch |err| {
        gpa.destroy(registry);
        orphan.* = null;
        trust_orphan.* = null;
        generation.deinit();
        gpa.destroy(trust);
        diagnostic.set("cannot load plugins: {s}", .{@errorName(err)});
        return .{ .failed = .{ .diagnostic = diagnostic, .mtime_ns = mtime_ns } };
    };
    registry.validateConfiguredActions(generation.snapshot.bindingSlice()) catch |err| {
        gpa.destroy(registry);
        orphan.* = null;
        trust_orphan.* = null;
        generation.deinit();
        gpa.destroy(trust);
        diagnostic.set("invalid configured plugin action: {s}", .{@errorName(err)});
        return .{ .failed = .{ .diagnostic = diagnostic, .mtime_ns = mtime_ns } };
    };
    registry_orphan.* = registry;
    return .{ .loaded = .{
        .generation = generation,
        .registry = registry,
        .trust_store = trust,
        .mtime_ns = generation.watchFingerprint(io, path) ^
            @as(i128, registry.watchFingerprint(gpa, io)) ^
            @as(i128, trustWatchFingerprint(io, trust_path)),
    } };
}

pub fn trustWatchFingerprint(io: Io, path: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0x74656c61722d7472);
    hasher.update(path);
    const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch {
        hasher.update("\x00missing");
        return hasher.final();
    };
    hasher.update(std.mem.asBytes(&stat.kind));
    hasher.update(std.mem.asBytes(&stat.size));
    hasher.update(std.mem.asBytes(&stat.mtime.nanoseconds));
    return hasher.final();
}

fn loadReloadTrustStore(
    gpa: std.mem.Allocator,
    io: Io,
    path: []const u8,
) !*core.plugin.TrustStore {
    const store = try gpa.create(core.plugin.TrustStore);
    errdefer gpa.destroy(store);
    const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => {
            store.* = .{};
            return store;
        },
        else => return err,
    };
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0)
        return error.InsecureTrustStore;
    const source = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024));
    defer gpa.free(source);
    store.* = try core.plugin.TrustStore.parse(gpa, source);
    return store;
}

fn readInput(io: Io, input: File) anyerror!InputChunk {
    var chunk: InputChunk = .{};
    chunk.len = @intCast(try input.readStreaming(io, &.{&chunk.bytes}));
    return chunk;
}

const InputHandler = struct {
    client: *Client,
    redraw: bool = false,

    fn activeModel(handler: *InputHandler) *multiplexer.Model {
        return &handler.client.tabs.active().?.model;
    }

    fn detachTab(handler: *InputHandler, tab: *tabs_mod.Tab) !void {
        for (&tab.model.panes) |*slot| {
            const pane = if (slot.*) |*item| item else continue;
            if (!pane.attached) continue;
            try handler.client.enqueue(.{ .detach_pane = .{
                .pane_id = pane.id,
            } });
            try handler.client.graphics_store.setPaneVisible(pane.id, false);
        }
        tabs_mod.Model.detachAll(tab);
    }

    fn selectTab(handler: *InputHandler, tab_id: schema.TabId) !void {
        if (handler.client.requests.has(.tab_snapshot)) return;
        const current = handler.client.tabs.active() orelse return;
        if (current.location.tab_id == tab_id) return;
        if (handler.client.tabs.indexOf(tab_id) == null) return;
        try handler.detachTab(current);
        std.debug.assert(handler.client.tabs.select(tab_id));
        const active = handler.client.tabs.active().?;
        for (&active.model.panes) |*slot| {
            const pane = if (slot.*) |*item| item else continue;
            try handler.client.graphics_store.setPaneVisible(pane.id, true);
        }
        active.model.composition_invalidated = true;
        const request_id = try handler.client.nextId();
        try handler.client.enqueueRequest(
            request_id,
            .{ .tab_snapshot = active.location },
            .{ .request_tab_snapshot = .{
                .request_id = request_id,
                .location = active.location,
            } },
        );
        handler.client.view.invalidate();
        handler.redraw = true;
    }

    pub fn forward(handler: *InputHandler, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        if (handler.client.view.renamedTab() != null) {
            switch (handler.client.view.handleRenameInput(bytes)) {
                .editing, .cancelled => {},
                .submitted => |label| try handler.submitTabRename(label),
            }
            handler.redraw = true;
            return;
        }
        const pane = handler.activeModel().focusedPane() orelse return;
        if (!pane.attached) return;
        try handler.sendPaneBytes(pane, bytes);
    }

    pub fn key(handler: *InputHandler, value: keybind.Key) !void {
        if (handler.client.view.renamedTab() != null) {
            var editing_bytes: [32]u8 = undefined;
            return handler.forward(try input_mod.encodeKey(&editing_bytes, value, .{}));
        }
        const pane = handler.activeModel().focusedPane() orelse return;
        if (!pane.attached) return;
        var encoded: [32]u8 = undefined;
        try handler.sendPaneBytes(
            pane,
            try input_mod.encodeKey(&encoded, value, pane.input_modes),
        );
    }

    fn sendPaste(handler: *InputHandler, text: []const u8) !void {
        const pane = handler.activeModel().focusedPane() orelse return;
        if (!pane.attached) return;
        var encoded: [lua_config.max_expression_paste_bytes + 16]u8 = undefined;
        try handler.sendPaneBytes(
            pane,
            try input_mod.encodePaste(&encoded, text, pane.input_modes),
        );
    }

    pub fn pasteStart(handler: *InputHandler) !void {
        if (handler.client.view.renamedTab() != null)
            return handler.forward("\x1b[200~");
        const pane = handler.activeModel().focusedPane() orelse return;
        if (!pane.attached) return;
        handler.client.paste_pane = pane.id;
        if (pane.input_modes.bracketed_paste)
            try handler.sendPaneBytes(pane, "\x1b[200~");
    }

    pub fn pasteContent(handler: *InputHandler, text: []const u8) !void {
        if (handler.client.view.renamedTab() != null) return handler.forward(text);
        const pane_id = handler.client.paste_pane orelse return;
        const pane = handler.client.tabs.findPane(pane_id) orelse return;
        if (pane.attached) try handler.sendPaneBytes(pane, text);
    }

    pub fn pasteEnd(handler: *InputHandler) !void {
        if (handler.client.view.renamedTab() != null)
            return handler.forward("\x1b[201~");
        const pane_id = handler.client.paste_pane orelse return;
        handler.client.paste_pane = null;
        const pane = handler.client.tabs.findPane(pane_id) orelse return;
        if (pane.attached and pane.input_modes.bracketed_paste)
            try handler.sendPaneBytes(pane, "\x1b[201~");
    }

    fn sendPaneBytes(
        handler: *InputHandler,
        pane: *multiplexer.Pane,
        bytes: []const u8,
    ) !void {
        const started = diagnostics.now(handler.client.io);
        try handler.client.enqueueInput(pane.id, bytes);
        if (comptime diagnostics.enabled) {
            handler.client.metrics.input_events += 1;
            handler.client.metrics.input_bytes += bytes.len;
            handler.client.metrics.input_enqueue.observe(diagnostics.elapsed(started, diagnostics.now(handler.client.io)));
        }
    }

    pub fn mouse(handler: *InputHandler, event: term.Event.Mouse) !void {
        if (comptime diagnostics.enabled) handler.client.metrics.mouse_events += 1;
        const cell_size = handler.client.capabilities.cellSize(
            handler.client.view.scratch.w,
            handler.client.view.scratch.h,
        );
        const exterior_pixels = handler.client.capabilities.mouse_pixels == .supported and
            cell_size.width != 0 and cell_size.height != 0;
        var cell_event = event;
        if (exterior_pixels) {
            cell_event.x = std.math.cast(u16, event.raw_x / cell_size.width) orelse
                std.math.maxInt(u16);
            cell_event.y = std.math.cast(u16, event.raw_y / cell_size.height) orelse
                std.math.maxInt(u16);
        }
        const model = handler.activeModel();
        const interaction = handler.client.view.handleMouse(handler.client.tabs, model, cell_event);
        if (interaction.select_tab) |tab_id| try handler.selectTab(tab_id);
        if (interaction.layout_changed) {
            try handler.client.resizeAttached(
                handler.activeModel(),
                handler.client.view.workbench(),
            );
        }
        handler.redraw = handler.redraw or interaction.redraw;
        if (interaction.select_tab != null or !handler.client.view.workbench().contains(cell_event.x, cell_event.y)) return;
        const pane = model.focusedPane() orelse return;
        const pane_view = model.viewForPane(pane.id, handler.client.view.workbench()) orelse return;
        if (!pane_view.content.contains(cell_event.x, cell_event.y) or !pane.mouse.sgr or
            !mouseTracked(pane.mouse.tracking, cell_event.kind)) return;
        var encoded: [64]u8 = undefined;
        const exact_x: ?u32 = if (pane.mouse.pixels and exterior_pixels)
            event.raw_x - @as(u32, pane_view.content.x) * cell_size.width
        else
            null;
        const exact_y: ?u32 = if (pane.mouse.pixels and exterior_pixels)
            event.raw_y - @as(u32, pane_view.content.y) * cell_size.height
        else
            null;
        const bytes = try encodeSgrMouse(
            &encoded,
            cell_event,
            cell_event.x - pane_view.content.x,
            cell_event.y - pane_view.content.y,
            pane.mouse.pixels,
            cell_size.width,
            cell_size.height,
            exact_x,
            exact_y,
        );
        try handler.client.enqueueInput(pane.id, bytes);
    }

    pub fn terminalResponse(handler: *InputHandler, response: term.Event.TerminalResponse) !void {
        if (!handler.client.capabilities.observe(response)) return;
        const cell_size = handler.client.capabilities.cellSize(
            handler.client.view.scratch.w,
            handler.client.view.scratch.h,
        );
        for (handler.client.tabs.items[0..handler.client.tabs.count]) |*slot| {
            const tab = if (slot.*) |*value| value else continue;
            tab.model.setCellSize(cell_size.width, cell_size.height);
            for (&tab.model.panes) |*pane_slot| {
                const pane = if (pane_slot.*) |*value| value else continue;
                tab.model.setGraphicsPlaceholder(pane.id, handler.client.capabilities.kitty_graphics != .supported and
                    handler.client.graphics_store.hasPaneGraphics(pane.id));
            }
        }
        handler.client.graphics_store.invalidatePlacements();
        try handler.client.view.configureSidebar(
            handler.client.sidebar_rendering,
            handler.client.capabilities.kitty_graphics,
            cell_size.width,
            cell_size.height,
        );
        if (handler.client.tabs.active()) |active|
            try handler.client.resizeAttached(&active.model, handler.client.view.workbench());
        handler.client.view.invalidate();
        handler.redraw = true;
    }

    pub fn action(handler: *InputHandler, value: Action) !keybind.Control {
        if (handler.client.view.renamedTab() != null) return .continue_routing;
        switch (value) {
            .lua_callback => |reference| {
                const generation = handler.client.lua_generation.* orelse
                    return .continue_routing;
                const batch = generation.invokeCallback(
                    reference,
                    handler.callbackContext(),
                    &handler.client.config_diagnostic,
                ) catch {
                    handler.redraw = true;
                    return .continue_routing;
                };
                for (batch.slice()) |effect| switch (effect) {
                    .plugin => |requested| {
                        const registry = handler.client.plugin_registry.* orelse {
                            handler.client.config_diagnostic.set(
                                "Lua callback referenced a plugin but no registry is active",
                                .{},
                            );
                            handler.redraw = true;
                            return .continue_routing;
                        };
                        _ = registry.resolve(requested) catch |err| {
                            handler.client.config_diagnostic.set(
                                "Lua callback returned an invalid plugin action: {s}",
                                .{@errorName(err)},
                            );
                            handler.redraw = true;
                            return .continue_routing;
                        };
                    },
                    else => {},
                };
                handler.client.config_diagnostic.len = 0;
                for (batch.slice()) |effect|
                    if (try handler.action(effect) == .stop) return .stop;
                return .continue_routing;
            },
            .lua_expr => |reference| {
                const generation = handler.client.lua_generation.* orelse
                    return .continue_routing;
                const decision = generation.invokeExpression(
                    reference,
                    handler.callbackContext(),
                    &handler.client.config_diagnostic,
                ) catch {
                    handler.redraw = true;
                    return .continue_routing;
                };
                handler.client.config_diagnostic.len = 0;
                switch (decision) {
                    .consume => {},
                    .forward_binding => |keys| for (keys.slice()) |key_value|
                        try handler.key(key_value),
                    .keys => |keys| for (keys.slice()) |key_value|
                        try handler.key(key_value),
                    .paste => |paste| try handler.sendPaste(paste.slice()),
                }
                return .continue_routing;
            },
            .plugin => |requested| {
                if (handler.client.plugin_pending) return .continue_routing;
                const registry = handler.client.plugin_registry.* orelse
                    return .continue_routing;
                const invocation = registry.resolve(requested) catch |err| {
                    handler.client.config_diagnostic.set(
                        "plugin action cannot be resolved: {s}",
                        .{@errorName(err)},
                    );
                    handler.redraw = true;
                    return .continue_routing;
                };
                const request = try registry.workerRequest(
                    invocation,
                    handler.callbackContext(),
                );
                try handler.client.select.concurrent(
                    .plugin_result,
                    plugin_broker.executeWorker,
                    .{ handler.client.io, handler.client.gpa, request },
                );
                handler.client.plugin_pending = true;
                return .continue_routing;
            },
            else => return handler.applyNativeAction(value),
        }
    }

    fn applyNativeAction(handler: *InputHandler, value: Action) !keybind.Control {
        switch (value) {
            .split_pane => |direction| try handler.beginSplit(switch (direction) {
                .horizontal => .horizontal,
                .vertical => .vertical,
            }),
            .focus_pane => |direction| handler.moveFocus(switch (direction) {
                .left => .left,
                .right => .right,
                .up => .up,
                .down => .down,
            }),
            .toggle_sidebar => {
                handler.client.view.toggleSidebar();
                try handler.client.resizeAttached(
                    handler.activeModel(),
                    handler.client.view.workbench(),
                );
                handler.redraw = true;
            },
            .close_pane => try handler.closeFocused(),
            .new_tab => try handler.createTab(),
            .select_tab_offset => |offset| try handler.selectTabOffset(offset),
            .select_tab => |position| try handler.selectTabPosition(position),
            .rename_tab => if (handler.client.tabs.active()) |tab| {
                handler.client.view.beginTabRename(tab.location.tab_id, tab.labelSlice());
                handler.redraw = true;
            },
            .close_tab => try handler.closeTab(),
            .move_tab => |direction| try handler.moveTab(switch (direction) {
                .previous => .previous,
                .next => .next,
            }),
            .detach => {
                for (handler.client.tabs.items[0..handler.client.tabs.count]) |*slot| {
                    const tab = if (slot.*) |*item| item else continue;
                    try handler.detachTab(tab);
                }
                return .stop;
            },
            .lua_callback, .lua_expr, .plugin => unreachable,
        }
        return .continue_routing;
    }

    fn callbackContext(handler: *InputHandler) lua_config.CallbackContext {
        const model = handler.activeModel();
        const focused = model.focusedPane();
        return .{
            .sidebar_visible = handler.client.view.sidebar_requested,
            .tab_count = @intCast(handler.client.tabs.count),
            .active_tab_index = @intCast(handler.client.tabs.activeIndex() orelse 0),
            .pane_count = @intCast(model.pane_count),
            .focused_pane_id = if (focused) |pane| schema.id.raw(pane.id) else 0,
        };
    }

    fn beginSplit(handler: *InputHandler, axis: layout_mod.Axis) !void {
        if (handler.client.requests.has(.pane_operation)) return;
        const model = handler.activeModel();
        const pane = model.focusedPane() orelse return;
        if (!pane.attached) return;
        const location = model.location orelse return;
        const prospective = model.prospectiveSplit(
            pane.id,
            axis,
            handler.client.view.workbench(),
        ) orelse
            return;
        const existing_size = rectSize(prospective.existing_content) orelse return;
        const new_size = rectSize(prospective.new_content) orelse return;
        const request_id = try handler.client.nextId();

        try handler.client.enqueue(.{ .pane_resize = .{
            .pane_id = pane.id,
            .size = existing_size,
        } });
        handler.client.enqueueRequest(
            request_id,
            .{ .split = .{
                .target_pane = pane.id,
                .location = location,
                .axis = axis,
            } },
            .{ .create_pane = .{
                .request_id = request_id,
                .location = location,
                .size = new_size,
                .launch = .{ .cwd = handler.client.options.cwd, .arguments = handler.client.options.arguments },
            } },
        ) catch |err| {
            try handler.restoreFocusedSize(pane.id);
            return err;
        };
    }

    fn restoreFocusedSize(handler: *InputHandler, pane_id: schema.PaneId) !void {
        const size = handler.activeModel().contentSize(pane_id, handler.client.view.workbench()) orelse return;
        try handler.client.enqueue(.{ .pane_resize = .{
            .pane_id = pane_id,
            .size = size,
        } });
    }

    fn moveFocus(handler: *InputHandler, direction: layout_mod.Direction) void {
        if (handler.activeModel().focusDirection(direction, handler.client.view.workbench()) != null) {
            handler.client.view.invalidate();
            handler.redraw = true;
        }
    }

    fn closeFocused(handler: *InputHandler) !void {
        if (handler.client.requests.has(.pane_operation)) return;
        const pane = handler.activeModel().focusedPane() orelse return;
        if (!pane.attached) return;
        const location = handler.client.tabs.active().?.location;
        const request_id = try handler.client.nextId();
        try handler.client.enqueueRequest(
            request_id,
            .{ .close_pane = .{ .pane_id = pane.id, .location = location } },
            .{ .close_pane = .{
                .request_id = request_id,
                .pane_id = pane.id,
            } },
        );
    }

    fn createTab(handler: *InputHandler) !void {
        if (handler.client.requests.has(.tab_operation)) return;
        const workspace = handler.client.tabs.workspace orelse return;
        const request_id = try handler.client.nextId();
        try handler.client.enqueueRequest(
            request_id,
            .{ .create_tab = workspace },
            .{ .create_tab = .{
                .request_id = request_id,
                .workspace = workspace,
                .size = rectSize(handler.client.view.workbench()) orelse return,
                .launch = .{ .cwd = handler.client.options.cwd, .arguments = handler.client.options.arguments },
            } },
        );
    }

    fn selectTabOffset(handler: *InputHandler, offset: isize) !void {
        if (handler.client.tabs.count < 2) return;
        const count: isize = @intCast(handler.client.tabs.count);
        const current: isize = @intCast(handler.client.tabs.active_index);
        const position: usize = @intCast(@mod(current + offset, count));
        try handler.selectTab(handler.client.tabs.items[position].?.location.tab_id);
    }

    fn selectTabPosition(handler: *InputHandler, position: usize) !void {
        if (position >= handler.client.tabs.count) return;
        try handler.selectTab(handler.client.tabs.items[position].?.location.tab_id);
    }

    fn closeTab(handler: *InputHandler) !void {
        if (handler.client.requests.has(.tab_operation)) return;
        const tab = handler.client.tabs.active() orelse return;
        const request_id = try handler.client.nextId();
        try handler.detachTab(tab);
        try handler.client.enqueueRequest(
            request_id,
            .{ .close_tab = tab.location },
            .{ .close_tab = .{
                .request_id = request_id,
                .location = tab.location,
            } },
        );
    }

    fn moveTab(handler: *InputHandler, direction: schema.TabMoveDirection) !void {
        if (handler.client.requests.has(.tab_operation)) return;
        const tab = handler.client.tabs.active() orelse return;
        const request_id = try handler.client.nextId();
        try handler.client.enqueueRequest(
            request_id,
            .{ .move_tab = tab.location },
            .{ .move_tab = .{
                .request_id = request_id,
                .location = tab.location,
                .direction = direction,
            } },
        );
    }

    fn submitTabRename(handler: *InputHandler, label: []const u8) !void {
        if (handler.client.requests.has(.tab_operation)) return;
        const tab_id = handler.client.view.renamedTab() orelse return;
        const tab = handler.client.tabs.find(tab_id) orelse return;
        const request_id = try handler.client.nextId();
        try handler.client.enqueueRenameRequest(
            .{
                .request_id = request_id,
                .location = tab.location,
                .label = label,
            },
            .{ .rename_tab = tab.location },
        );
        handler.client.view.finishTabRename();
    }
};

const defaultBindings = default_bindings.load;

/// Drops every image, placement, and revision the store holds for the panes
/// of a tab that no longer exists.
fn releaseTabGraphics(store: *kitty.Store, tab: *tabs_mod.Tab) void {
    for (&tab.model.panes) |*slot| {
        const pane = if (slot.*) |*value| value else continue;
        store.clearPane(pane.id);
    }
}

/// The model a due draw should present, or null while the client is not
/// presentable yet. Unwrapping the active tab here used to panic when a
/// resize arrived before the runtime answered the initial open request.
fn presentableModel(tabs: *tabs_mod.Model) ?*multiplexer.Model {
    const active = tabs.active() orelse return null;
    return &active.model;
}

fn scheduleInputTimers(
    io: Io,
    select: *Io.Select(ClientEvent),
    router: *const InputRouter,
    input_pending: *bool,
    binding_pending: *bool,
) !void {
    if (!input_pending.*) {
        if (router.inputDeadline()) |deadline| {
            input_pending.* = true;
            select.concurrent(.input_timeout, waitUntil, .{ io, deadline }) catch |err| {
                input_pending.* = false;
                return err;
            };
        }
    }
    if (!binding_pending.*) {
        if (router.bindingDeadline()) |deadline| {
            binding_pending.* = true;
            select.concurrent(.binding_timeout, waitUntil, .{ io, deadline }) catch |err| {
                binding_pending.* = false;
                return err;
            };
        }
    }
}

fn waitUntil(io: Io, deadline_ns: u64) anyerror!void {
    const deadline = Io.Timestamp.fromNanoseconds(@intCast(deadline_ns)).withClock(.awake);
    try deadline.wait(io);
}

fn waitResize(io: Io, watcher: *platform.ResizeWatcher) anyerror!void {
    return watcher.wait(io);
}

fn receive(io: Io, connection: *core.transport.SocketChannel, buffer: []u8) anyerror![]u8 {
    return connection.receive(io, buffer);
}

fn sendClient(
    io: Io,
    connection: *core.transport.SocketChannel,
    payload: []const u8,
) anyerror!void {
    return connection.send(io, payload);
}

const CombinedGraphicsWriter = struct {
    panes: kitty.KittyGraphicsWriter,
    sidebar: *kitty.KittySidebarRenderer,
    metrics: *ClientMetrics,

    fn writeOpaque(context: *anyopaque, writer: *Io.Writer) Io.Writer.Error!usize {
        const self: *CombinedGraphicsWriter = @ptrCast(@alignCast(context));
        const pane_bytes = try self.panes.write(writer);
        // An open budget-paced transfer owns the graphics stream; the sidebar
        // keeps its dirty flags and emits once the transfer closes.
        var sidebar_bytes: usize = 0;
        if (self.panes.store.partial == null)
            sidebar_bytes = try self.sidebar.write(writer);
        if (comptime diagnostics.enabled) {
            self.metrics.pane_graphics_flushed_bytes += pane_bytes;
            self.metrics.sidebar_graphics_flushed_bytes += sidebar_bytes;
        }
        return pane_bytes + sidebar_bytes;
    }
};

fn flushScreen(
    io: Io,
    screen: *term.Screen,
    writer: *Io.Writer,
    metrics: *ClientMetrics,
) !void {
    const started = diagnostics.now(io);
    const stats = try screen.flush(writer);
    if (comptime diagnostics.enabled) {
        metrics.flushes += 1;
        metrics.scanned_cells += stats.scanned;
        metrics.flushed_cells += stats.cells;
        metrics.flushed_bytes += stats.bytes;
        metrics.graphics_flushed_bytes += stats.graphics_bytes;
        metrics.flush.observe(diagnostics.elapsed(started, diagnostics.now(io)));
    }
}

fn writeDiagnostics(io: Io, sink: *diagnostics.Sink, bytes: []const u8) anyerror!void {
    try sink.write(io, bytes);
}

fn waitToDraw(io: Io, deadline_ns: u64) anyerror!void {
    const deadline = Io.Timestamp.fromNanoseconds(@intCast(deadline_ns)).withClock(.awake);
    try deadline.wait(io);
}

fn waitCapabilityTimeout(io: Io) anyerror!void {
    const now = monotonic(io);
    const deadline = Io.Timestamp.fromNanoseconds(@intCast(now + kitty.capability_timeout_ns)).withClock(.awake);
    try deadline.wait(io);
}

fn monotonic(io: Io) u64 {
    const timestamp = Io.Timestamp.now(io, .awake);
    return @intCast(@max(timestamp.nanoseconds, 0));
}

fn terminalSize(tty: *const platform.Tty) schema.TerminalSize {
    const size = tty.size();
    const cols = if (size.cols == 0) 80 else size.cols;
    const rows = if (size.rows == 0) 24 else size.rows;
    return .{
        .cols = cols,
        .rows = rows,
        .cell_width_px = if (size.width_px == 0) 0 else size.width_px / cols,
        .cell_height_px = if (size.height_px == 0) 0 else size.height_px / rows,
    };
}

const rectSize = multiplexer.rectSize;

fn nextRequestId(next: *u64) !schema.RequestId {
    if (next.* == 0 or next.* == std.math.maxInt(u64))
        return error.RequestIdExhausted;
    const value = next.*;
    next.* += 1;
    return @enumFromInt(value);
}

test {
    // This file is the client's suite root, so the client-only modules with
    // no suite root of their own get their tests collected here.
    _ = @import("diff.zig");
    _ = @import("kitty.zig");
    _ = @import("client_ui.zig");
    _ = @import("client_requests.zig");
    _ = @import("tabs.zig");
    _ = @import("theme.zig");
    _ = @import("platform.zig");
}

test "configured action names cover multiplexer operations" {
    try std.testing.expectEqualDeep(Action.detach, try Action.parse("detach"));
    try std.testing.expectEqualDeep(
        Action{ .split_pane = .horizontal },
        try Action.parse("split-horizontal"),
    );
    try std.testing.expectEqualDeep(Action.close_pane, try Action.parse("close-pane"));
    try std.testing.expectEqualDeep(Action.toggle_sidebar, try Action.parse("toggle-sidebar"));
    try std.testing.expectError(error.UnknownAction, Action.parse("rename-pane"));
}

test "default bindings compile without ambiguous prefixes" {
    var bindings = try defaultBindings();
    _ = try InputRouter.init(&bindings);
}

test "pane mouse reports preserve SGR buttons and pane-relative coordinates" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "\x1b[<0;3;5M",
        try encodeSgrMouse(&buffer, .{ .x = 20, .y = 30, .kind = .press, .button = 0 }, 2, 4, false, 0, 0, null, null),
    );
    try std.testing.expectEqualStrings(
        "\x1b[<0;3;5m",
        try encodeSgrMouse(&buffer, .{ .x = 20, .y = 30, .kind = .release, .button = 0 }, 2, 4, false, 0, 0, null, null),
    );
    try std.testing.expectEqualStrings(
        "\x1b[<0;26;91M",
        try encodeSgrMouse(&buffer, .{ .x = 20, .y = 30, .kind = .press, .button = 0 }, 2, 4, true, 10, 20, null, null),
    );
    try std.testing.expectEqualStrings(
        "\x1b[<0;8;10M",
        try encodeSgrMouse(&buffer, .{ .x = 20, .y = 30, .kind = .press, .button = 0 }, 2, 4, true, 10, 20, 7, 9),
    );
    try std.testing.expect(mouseTracked(.any, .move));
    try std.testing.expect(!mouseTracked(.button, .move));
    try std.testing.expect(mouseTracked(.x10, .press));
    try std.testing.expect(!mouseTracked(.x10, .release));
}

test "a draw scheduled before the first tab bootstraps is dropped" {
    // A true red for the original defect is a null unwrap inside the event
    // loop, which a test cannot expect; the guard is factored out so the
    // pre-bootstrap case is provable here instead.
    var tabs = tabs_mod.Model.init(std.testing.allocator);
    defer tabs.deinit();
    try std.testing.expectEqual(@as(?*multiplexer.Model, null), presentableModel(&tabs));

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    try tabs.bootstrap(@enumFromInt(1), .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(presentableModel(&tabs) != null);
}

test "closing a tab releases the graphics its panes held" {
    // Red is infeasible in-process: the leak is the *absence* of this call in
    // the `.tab_closed` arm, which needs a live event loop to drive. The
    // helper the arm now calls is proven here instead.
    var tabs = tabs_mod.Model.init(std.testing.allocator);
    defer tabs.deinit();
    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    try tabs.bootstrap(@enumFromInt(7), .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    }, .{ .cols = 20, .rows = 5 });

    var store = kitty.Store.init(std.testing.allocator);
    defer store.deinit();
    try store.applyImage(.{ .pane_id = @enumFromInt(7), .revision = 1, .image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgb,
        .width = 1,
        .height = 1,
        .byte_len = 3,
    } });
    try std.testing.expect(store.hasPaneGraphics(@enumFromInt(7)));

    releaseTabGraphics(&store, tabs.active().?);
    try std.testing.expect(!store.hasPaneGraphics(@enumFromInt(7)));
    try std.testing.expectEqual(@as(usize, 0), store.total_bytes);
}
