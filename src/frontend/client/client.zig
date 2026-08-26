//! One attached client: the long-lived objects `run` owns by pointer, plus
//! every piece of pending-request and frame-pacing state that used to be a
//! loose local threaded through fourteen-argument calls.

const std = @import("std");
const core = @import("telar-core");
const input_capability = @import("../input/root.zig");
const presentation = @import("../presentation/root.zig");
const workspace_capability = @import("../workspace/root.zig");
const graphics = @import("../graphics/root.zig");
const action_mod = input_capability.action;
const client_outbox = @import("outbox.zig");
const client_requests = @import("requests.zig");
const client_telemetry = @import("telemetry.zig");
const client_view = @import("view.zig");
const lua_config = @import("../config/root.zig");
const copy_mode = input_capability.copy_mode;
const input_mod = input_capability.host;
const keybind = input_capability.keybind;
const mouse_protocol = input_capability.mouse_protocol;
const kitty = graphics.kitty;
const toast_graphics = graphics.toast;
const layout_mod = workspace_capability.layout;
const multiplexer = workspace_capability.multiplexer;
const tabs_mod = workspace_capability.tabs;
const pace = presentation.pace;
const term = presentation.screen;
const platform = @import("../platform/root.zig");
const plugin_broker = @import("../plugins/root.zig");
const ui_capability = @import("../ui/root.zig");
const theme = ui_capability.theme;
const widgets = @import("../widgets/root.zig");

const Io = std.Io;
const File = Io.File;
const schema = core.schema;
const diagnostics = core.diagnostics;
const ui = core.ui;

const input_chunk_size = 4096;
const max_bindings = lua_config.max_bindings;
const max_binding_keys = lua_config.default_binding_max_keys;
const held_binding_bytes = 128;

const Action = action_mod.Action;
const ConfiguredBinding = lua_config.ConfiguredBinding;
pub const InputRouter = keybind.Router(
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
    prefix: keybind.Key = keybind.default_prefix,
    bindings: []const ConfiguredBinding = &.{},
    theme: theme.Theme = theme.default_theme,
    sidebar_rendering: kitty.SidebarRendering = .automatic,
    sidebar_visible: bool = true,
    pane_gaps: bool = true,
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
const InputHandler = @import("input_handler.zig");

pub const ClientEvent = union(enum) {
    input: anyerror!InputChunk,
    input_timeout: anyerror!void,
    binding_timeout: anyerror!void,
    capability_timeout: anyerror!void,
    resized: anyerror!void,
    server: anyerror![]u8,
    sent: anyerror!void,
    draw: anyerror!void,
    sidebar_animation_tick: anyerror!void,
    notification_tick: anyerror!void,
    telemetry_tick: anyerror!void,
    telemetry_written: anyerror!void,
    config_reload: anyerror!ConfigReload,
    plugin_result: anyerror!plugin_broker.WorkerResult,
};

pub const NotificationTimer = struct {
    deadline_ns: std.atomic.Value(u64) = .init(std.math.maxInt(u64)),
    wake: Io.Event = .unset,
};

const NotificationTimerEvent = union(enum) {
    deadline: anyerror!void,
    rescheduled: anyerror!void,
};

const NotificationTimerResult = enum {
    deadline,
    rescheduled,
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

const WorkspaceClosureAction = union(enum) {
    stay,
    exit,
    switch_to: schema.WorkspaceId,
};

fn workspaceClosureAction(
    workspace_closed: bool,
    previous_workspace: ?schema.WorkspaceId,
) WorkspaceClosureAction {
    if (!workspace_closed) return .stay;
    return if (previous_workspace) |workspace| .{ .switch_to = workspace } else .exit;
}

fn failureTitle(continuation: client_requests.Continuation) []const u8 {
    return switch (continuation) {
        .split => "Could not split pane",
        .close_pane => "Could not close pane",
        .attach_pane => "Could not attach pane",
        .create_workspace => "Could not create workspace",
        .rename_workspace => "Could not rename workspace",
        .create_tab => "Could not create tab",
        .rename_tab => "Could not rename tab",
        .close_tab => "Could not close tab",
        .move_tab => "Could not move tab",
        .notification => "Could not show notification",
        .initial_open, .workspace_snapshot, .tab_snapshot => "Runtime request failed",
        .ignored => "Request ignored",
    };
}

fn notificationTarget(
    continuation: client_requests.Continuation,
) widgets.notification.Target {
    return switch (continuation) {
        .split => |split| .{ .focus_pane = split.target_pane },
        .close_pane, .attach_pane => |operation| .{ .select_tab = operation.location.tab_id },
        .tab_snapshot, .rename_tab, .close_tab, .move_tab => |location| .{
            .select_tab = location.tab_id,
        },
        .rename_workspace, .workspace_snapshot => |location| workspaceNotificationTarget(location),
        .create_tab => |location| workspaceNotificationTarget(location),
        .initial_open, .create_workspace, .notification, .ignored => .none,
    };
}

fn workspaceNotificationTarget(location: schema.WorkspaceLocation) widgets.notification.Target {
    return switch (location) {
        .workspace => |workspace| .{ .select_workspace = workspace },
        .worktree => .none,
    };
}

fn agentProviderName(provider: schema.AgentProvider) []const u8 {
    return switch (provider) {
        .unknown => "Agent",
        .claude => "Claude",
        .codex => "Codex",
    };
}

fn agentStatusName(status: schema.AgentStatus) []const u8 {
    return switch (status) {
        .blocked => "waiting for input",
        .ready => "ready",
        .failed => "failed",
        .unknown, .working => "active",
    };
}

fn shouldNotifyAgentStatus(previous: ?schema.AgentStatus, current: schema.AgentStatus) bool {
    const before = previous orelse return false;
    if (before == current) return false;
    return current == .blocked or current == .ready or current == .failed;
}

/// The request that opens the first pane; everything else is numbered by
/// `Client.nextId`.
pub const initial_request_id: schema.RequestId = @enumFromInt(1);

const client_event_count = @typeInfo(ClientEvent).@"union".fields.len;

/// The platform resources a client cannot fabricate: everything else it
/// owns. Substituting these — a pipe for the tty's read handle, a
/// fixed-buffer writer, a scripted socket peer — is what makes the client
/// constructible in a test.
pub const Params = struct {
    gpa: std.mem.Allocator,
    io: Io,
    connection: *core.transport.SocketChannel,
    input_file: File,
    writer: *Io.Writer,
    /// Host terminal geometry measured by the platform adapter.
    host_size: schema.TerminalSize,
    window_width_px: u32 = 0,
    window_height_px: u32 = 0,
    options: Options,
};

io: Io,
gpa: std.mem.Allocator,
connection: *core.transport.SocketChannel,
send_buffer: []u8,
receive_buffer: []u8,
outbox: client_outbox.Outbox = .{},
writer: *Io.Writer,
select: Io.Select(ClientEvent),
select_storage: [client_event_count]ClientEvent = undefined,
options: Options,
metrics: ClientMetrics,
screen: term.Screen,
view: client_view.State,
tabs: tabs_mod.Model,
graphics_store: kitty.Store,
capabilities: kitty.TerminalCapabilities,
host_size: schema.TerminalSize,
input_file: File,
input_router: InputRouter,
input_timeout_pending: bool = false,
binding_timeout_pending: bool = false,
telemetry_buffer: [4096]u8 = undefined,
telemetry_write_pending: bool = false,
lua_generation: ?*lua_config.Generation,
config_diagnostic: lua_config.Diagnostic = .{},
plugin_registry: ?*plugin_broker.Registry,
trust_store: ?*core.plugin.TrustStore,
/// Race-window handoff slots for the async config-reload task: it publishes
/// freshly loaded objects here so a cancelled reload can still be freed by
/// `deinit`; the reload entrypoint clears them when it adopts the objects.
reload_generation_orphan: ?*lua_config.Generation = null,
reload_registry_orphan: ?*plugin_broker.Registry = null,
reload_trust_orphan: ?*core.plugin.TrustStore = null,
sidebar_rendering: kitty.SidebarRendering,
config_mtime_ns: i128,
next_config_generation: u64 = 2,
plugin_pending: bool = false,
paste_pane: ?schema.PaneId = null,
copy_mode_state: ?copy_mode.State = null,
/// Owns the cwd borrowed by one queued `create_workspace` launch.
workspace_create_path: [schema.max_cwd_bytes]u8 = undefined,
workspace_create_path_len: u16 = 0,
workspace_create_name: [schema.max_tab_label_bytes]u8 = undefined,
workspace_create_name_len: u8 = 0,

input_read_pending: bool = false,
next_request_id: u64 = 2,
requests: client_requests.Tracker = .{},
pacer: pace.Pacer = .{},
draw_pending: bool = false,
draw_due_ns: u64 = 0,
pending_updates: usize = 0,
last_presented_ns: ?u64 = null,
/// When the host terminal last delivered input bytes. Zero until the
/// first read, so a fresh session starts on the boosted media budget.
last_input_ns: u64 = 0,
sidebar_animation_pending: bool = false,
notification_tick_pending: bool = false,
notification_timer: NotificationTimer = .{},
reported_focus: ?schema.PaneId = null,
reported_focus_events: bool = false,

const Client = @This();

/// Creates a heap-owned client (the tab models alone are megabytes) and
/// takes ownership of the configuration generation, plugin registry and
/// trust store carried inside `params.options`; `deinit` releases them.
pub fn init(params: Params) !*Client {
    const gpa = params.gpa;
    const client = try gpa.create(Client);
    errdefer gpa.destroy(client);
    var capabilities: kitty.TerminalCapabilities = .{
        .window_width_px = params.window_width_px,
        .window_height_px = params.window_height_px,
    };
    var host_size = params.host_size;
    const cell_size = capabilities.cellSize(host_size.cols, host_size.rows);
    host_size.cell_width_px = cell_size.width;
    host_size.cell_height_px = cell_size.height;
    var screen = try term.Screen.init(gpa, host_size.cols, host_size.rows);
    errdefer screen.deinit();
    var view = try client_view.State.initWithTheme(
        gpa,
        host_size.cols,
        host_size.rows,
        params.options.theme,
    );
    errdefer view.deinit();
    if (!params.options.sidebar_visible) view.toggleSidebar();
    try view.configureSidebar(
        params.options.sidebar_rendering,
        capabilities.kitty_graphics,
        cell_size.width,
        cell_size.height,
    );
    var tabs = tabs_mod.Model.init(gpa);
    errdefer tabs.deinit();
    tabs.setPaneGaps(params.options.pane_gaps);
    var graphics_store = if (params.options.host_shared_memory)
        kitty.Store.initSharedMemory(gpa)
    else
        kitty.Store.init(gpa);
    errdefer graphics_store.deinit();
    const receive_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    errdefer gpa.free(receive_buffer);
    const send_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    errdefer gpa.free(send_buffer);
    var input_router = try buildInputRouter(params.options.prefix, params.options.bindings);
    input_router.escape_timeout_ns = params.options.input_escape_timeout_ns;
    input_router.sequence_timeout_ns = params.options.input_sequence_timeout_ns;
    client.* = .{
        .io = params.io,
        .gpa = gpa,
        .connection = params.connection,
        .send_buffer = send_buffer,
        .receive_buffer = receive_buffer,
        .writer = params.writer,
        .select = undefined,
        .options = params.options,
        .metrics = .{ .started_ns = diagnostics.now(params.io) },
        .screen = screen,
        .view = view,
        .tabs = tabs,
        .graphics_store = graphics_store,
        .capabilities = capabilities,
        .host_size = host_size,
        .input_file = params.input_file,
        .input_router = input_router,
        .lua_generation = params.options.lua_generation,
        .plugin_registry = params.options.plugin_registry,
        .trust_store = params.options.trust_store,
        .sidebar_rendering = params.options.sidebar_rendering,
        .config_mtime_ns = params.options.config_mtime_ns,
    };
    // The select's storage lives inside the heap-stable client, so the
    // select can only be built once the client's address exists.
    client.select = Io.Select(ClientEvent).init(params.io, &client.select_storage);
    return client;
}

/// Cancels every in-flight select task first — the reload task publishes
/// into the orphan slots — then releases the orphans, the owned
/// configuration objects, and every buffer.
pub fn deinit(client: *Client) void {
    const gpa = client.gpa;
    client.select.cancelDiscard();
    if (client.reload_generation_orphan) |generation| generation.deinit();
    if (client.reload_registry_orphan) |registry| gpa.destroy(registry);
    if (client.reload_trust_orphan) |store| gpa.destroy(store);
    if (client.lua_generation) |generation| generation.deinit();
    if (client.plugin_registry) |registry| gpa.destroy(registry);
    if (client.trust_store) |store| gpa.destroy(store);
    client.graphics_store.deinit();
    client.tabs.deinit();
    client.view.deinit();
    client.screen.deinit();
    gpa.free(client.send_buffer);
    gpa.free(client.receive_buffer);
    gpa.destroy(client);
}

pub fn nextId(client: *Client) !schema.RequestId {
    return nextRequestId(&client.next_request_id);
}

pub fn enqueue(client: *Client, message: client_outbox.Message) !void {
    try client.outbox.push(message);
    try client.pumpOutbox();
}

pub fn enqueueInput(client: *Client, pane_id: schema.PaneId, bytes: []const u8) !void {
    try client.outbox.pushInput(pane_id, bytes);
    try client.pumpOutbox();
}

fn enqueueRename(client: *Client, rename: schema.RenameTab) !void {
    try client.outbox.pushRename(rename);
    try client.pumpOutbox();
}

fn enqueueWorkspaceRename(client: *Client, rename: schema.RenameWorkspace) !void {
    try client.outbox.pushWorkspaceRename(rename);
    try client.pumpOutbox();
}

pub fn enqueueRequest(
    client: *Client,
    request_id: schema.RequestId,
    continuation: client_requests.Continuation,
    message: client_outbox.Message,
) !void {
    try client.requests.add(request_id, continuation);
    errdefer _ = client.requests.take(request_id);
    try client.enqueue(message);
}

pub fn enqueueRenameRequest(
    client: *Client,
    rename: schema.RenameTab,
    continuation: client_requests.Continuation,
) !void {
    try client.requests.add(rename.request_id, continuation);
    errdefer _ = client.requests.take(rename.request_id);
    try client.enqueueRename(rename);
}

pub fn enqueueWorkspaceRenameRequest(
    client: *Client,
    rename: schema.RenameWorkspace,
) !void {
    try client.requests.add(rename.request_id, .{ .rename_workspace = rename.workspace });
    errdefer _ = client.requests.take(rename.request_id);
    try client.enqueueWorkspaceRename(rename);
}

pub fn enqueueNotificationRequest(
    client: *Client,
    request: schema.ShowNotification,
) !void {
    try client.requests.add(request.request_id, .notification);
    errdefer _ = client.requests.take(request.request_id);
    try client.outbox.pushNotification(request);
    try client.pumpOutbox();
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

fn scheduleSidebarAnimation(client: *Client) !void {
    if (client.sidebar_animation_pending or !client.view.sidebarNeedsAnimation()) return;
    const deadline_ns = monotonic(client.io) + 120 * std.time.ns_per_ms;
    client.sidebar_animation_pending = true;
    client.select.concurrent(.sidebar_animation_tick, waitUntil, .{
        client.io,
        deadline_ns,
    }) catch |err| {
        client.sidebar_animation_pending = false;
        return err;
    };
}

fn notify(client: *Client, input: widgets.notification.Input) !void {
    _ = client.view.notify(monotonic(client.io), input);
    try client.requestDraw();
    try client.scheduleNotificationTick();
}

fn notifyDiagnostic(client: *Client, title: []const u8) !void {
    try client.notify(.{
        .level = .failure,
        .title = title,
        .message = client.config_diagnostic.message(),
        .duration_ns = 7 * std.time.ns_per_s,
    });
}

pub fn scheduleNotificationTick(client: *Client) !void {
    const now_ns = monotonic(client.io);
    const deadline_ns = client.view.nextNotificationDeadline(
        now_ns,
        client.pacer.interval,
    ) orelse return;
    client.notification_timer.deadline_ns.store(deadline_ns, .release);
    if (client.notification_tick_pending) {
        client.notification_timer.wake.set(client.io);
        return;
    }

    // The previous timer has returned, so no waiter can observe this reset.
    // Its deadline is replaced from the authoritative notification state.
    client.notification_timer.wake.reset();
    client.notification_tick_pending = true;
    client.select.concurrent(.notification_tick, waitForNotificationTick, .{
        client.io,
        &client.notification_timer,
    }) catch |err| {
        client.notification_tick_pending = false;
        return err;
    };
}

pub fn clearPaneFocus(client: *Client) !void {
    const previous = client.reported_focus;
    const reports = client.reported_focus_events;
    client.forgetPaneFocus();
    if (!reports) return;
    const pane_id = previous orelse return;
    const pane = client.tabs.findPane(pane_id) orelse return;
    if (pane.attached) try client.enqueueInput(pane_id, "\x1b[O");
}

fn forgetPaneFocus(client: *Client) void {
    client.reported_focus = null;
    client.reported_focus_events = false;
}

pub fn syncPaneFocus(client: *Client, model: *multiplexer.Model) !void {
    const next_id = model.layout.focused();
    const next = if (next_id) |pane_id| model.find(pane_id) else null;
    const next_reports = if (next) |pane|
        pane.attached and pane.input_modes.focus_events
    else
        false;

    if (client.reported_focus == next_id) {
        if (next_reports and !client.reported_focus_events)
            try client.enqueueInput(next_id.?, "\x1b[I");
        client.reported_focus_events = next_reports;
        return;
    }

    try client.clearPaneFocus();
    client.reported_focus = next_id;
    client.reported_focus_events = next_reports;
    if (next_reports) try client.enqueueInput(next_id.?, "\x1b[I");
}

/// Entrypoint for bytes read from the host terminal. It owns the complete
/// routing decision: consume a Telar action or enqueue pane input.
pub fn handleHostInput(client: *Client, result: anyerror!InputChunk) !bool {
    client.input_read_pending = false;
    const chunk = try result;
    if (chunk.len == 0) return true;
    client.last_input_ns = monotonic(client.io);
    var handler: InputHandler = .{ .client = client };
    if (try client.input_router.feed(chunk.slice(), monotonic(client.io), &handler) == .stop)
        return true;
    if (handler.redraw) try client.requestDraw();
    try client.scheduleInputTimers();
    try client.scheduleInputRead();
    return false;
}

/// Entrypoint for one completed runtime socket read. It owns decode,
/// message dispatch, flow-control credit and receive rescheduling.
pub fn handleServerEvent(client: *Client, result: anyerror![]u8) !?u8 {
    const payload = try result;
    const decode_started = diagnostics.now(client.io);
    const message = try schema.decodeServer(payload);
    if (comptime diagnostics.enabled) {
        client.metrics.server_messages += 1;
        client.metrics.server_bytes += payload.len;
        switch (message) {
            .graphics_snapshot,
            .graphics_image,
            .graphics_shared_image,
            .graphics_image_chunk,
            .graphics_placement,
            .graphics_delete_image,
            .graphics_delete_placement,
            => {
                client.metrics.graphics_messages += 1;
                client.metrics.graphics_bytes += payload.len;
            },
            else => {},
        }
        client.metrics.decode.observe(
            diagnostics.elapsed(decode_started, diagnostics.now(client.io)),
        );
    }
    if (try client.handleServerMessage(message)) |status| return status;
    try client.returnGraphicsCredits();
    try client.select.concurrent(.server, receive, .{
        client.io,
        client.connection,
        client.receive_buffer,
    });
    return null;
}

pub fn handleInputTimeoutEvent(client: *Client, result: anyerror!void) !bool {
    try result;
    client.input_timeout_pending = false;
    var handler: InputHandler = .{ .client = client };
    if (try client.input_router.expireInput(monotonic(client.io), &handler) == .stop) return true;
    if (handler.redraw) try client.requestDraw();
    try client.scheduleInputTimers();
    return false;
}

pub fn handleBindingTimeoutEvent(client: *Client, result: anyerror!void) !bool {
    try result;
    client.binding_timeout_pending = false;
    var handler: InputHandler = .{ .client = client };
    if (try client.input_router.expireBinding(monotonic(client.io), &handler) == .stop) return true;
    if (handler.redraw) try client.requestDraw();
    try client.scheduleInputTimers();
    return false;
}

pub fn handleCapabilityTimeoutEvent(client: *Client, result: anyerror!void) !void {
    try result;
    if (!client.capabilities.expire()) return;
    const cell_size = client.capabilities.cellSize(client.host_size.cols, client.host_size.rows);
    try client.view.configureSidebar(
        client.sidebar_rendering,
        client.capabilities.kitty_graphics,
        cell_size.width,
        cell_size.height,
    );
    for (client.tabs.items[0..client.tabs.count]) |*slot| {
        const tab = if (slot.*) |*value| value else continue;
        for (&tab.model.panes) |*pane_slot| {
            const pane = if (pane_slot.*) |*value| value else continue;
            tab.model.setGraphicsPlaceholder(
                pane.id,
                client.graphics_store.hasPaneGraphics(pane.id),
            );
        }
    }
    client.view.invalidate();
    try client.requestDraw();
}

pub fn handleResizeEvent(
    client: *Client,
    result: anyerror!void,
    tty: *const platform.Tty,
    watcher: *platform.ResizeWatcher,
) !void {
    try result;
    client.host_size = terminalSize(tty);
    const platform_size = tty.size();
    if (platform_size.width_px != 0)
        client.capabilities.window_width_px = platform_size.width_px;
    if (platform_size.height_px != 0)
        client.capabilities.window_height_px = platform_size.height_px;
    const cell_size = client.capabilities.cellSize(client.host_size.cols, client.host_size.rows);
    client.host_size.cell_width_px = cell_size.width;
    client.host_size.cell_height_px = cell_size.height;
    try client.view.configureSidebar(
        client.sidebar_rendering,
        client.capabilities.kitty_graphics,
        cell_size.width,
        cell_size.height,
    );
    try client.screen.resize(client.host_size.cols, client.host_size.rows);
    try client.view.resize(client.host_size.cols, client.host_size.rows);
    if (client.tabs.active()) |active| {
        active.model.setCellSize(cell_size.width, cell_size.height);
        client.graphics_store.invalidatePlacements();
        try client.resizeAttached(&active.model, client.view.workbench());
    }
    // Pixel dimensions can change independently when the font or display
    // scale changes. Refresh both values without blocking the resize path.
    try client.writer.writeAll("\x1b[14t\x1b[16t");
    try client.writer.flush();
    try client.requestDraw();
    try client.select.concurrent(.resized, waitResize, .{ client.io, watcher });
}

pub fn handleSentEvent(client: *Client, result: anyerror!void) !void {
    try result;
    client.outbox.popSent();
    try client.returnGraphicsCredits();
    try client.scheduleInputRead();
}

pub fn handleDrawEvent(client: *Client, result: anyerror!void) !void {
    try result;
    try client.presentDue();
}

pub fn handleSidebarAnimationEvent(client: *Client, result: anyerror!void) !void {
    try result;
    client.sidebar_animation_pending = false;
    if (client.view.advanceSidebarAnimation()) try client.requestDraw();
    try client.scheduleSidebarAnimation();
}

pub fn handleNotificationTickEvent(client: *Client, result: anyerror!void) !void {
    try result;
    client.notification_tick_pending = false;
    if (client.view.advanceNotifications(monotonic(client.io))) try client.requestDraw();
    try client.scheduleNotificationTick();
}

pub fn handleTelemetryTickEvent(
    client: *Client,
    result: anyerror!void,
    telemetry: *diagnostics.Sink,
) void {
    result catch {
        telemetry.deinit(client.io);
        return;
    };
    if (!telemetry.available()) return;
    client.select.concurrent(.telemetry_tick, diagnostics.waitForTick, .{client.io}) catch {
        telemetry.deinit(client.io);
        return;
    };
    if (client.telemetry_write_pending) return;
    // Ticks can fire before the first tab exists; report nothing.
    const active = client.tabs.active() orelse return;
    const focused = active.model.layout.focused() orelse .invalid;
    const line = client_telemetry.format(
        &client.telemetry_buffer,
        client.io,
        &client.metrics,
        &client.pacer,
        .{
            .theme_name = client.view.theme.base.canonicalName(),
            .active_tab = active.location.tab_id,
            .tab_count = client.tabs.count,
            .focused_pane = focused,
            .pane_count = active.model.pane_count,
            .pending_updates = client.pending_updates,
            .draw_pending = client.draw_pending,
            .outbox = &client.outbox,
            .capabilities = &client.capabilities,
            .sidebar_rendering = client.view.sidebar_rendering,
        },
    ) catch return;
    client.telemetry_write_pending = true;
    client.select.concurrent(.telemetry_written, writeDiagnostics, .{
        client.io,
        telemetry,
        line,
    }) catch {
        client.telemetry_write_pending = false;
        telemetry.deinit(client.io);
    };
}

pub fn handleTelemetryWrittenEvent(
    client: *Client,
    result: anyerror!void,
    telemetry: *diagnostics.Sink,
) void {
    client.telemetry_write_pending = false;
    result catch telemetry.deinit(client.io);
}

pub fn scheduleConfigReload(client: *Client) !void {
    const path = client.options.config_path orelse return;
    try client.select.concurrent(.config_reload, waitConfigReload, .{
        client.io,
        client.gpa,
        path,
        client.config_mtime_ns,
        client.next_config_generation,
        client.options.profile,
        client.lua_generation.?,
        client.plugin_registry.?,
        client.options.trust_path.?,
        &client.reload_generation_orphan,
        &client.reload_registry_orphan,
        &client.reload_trust_orphan,
    });
}

pub fn handleConfigReloadEvent(client: *Client, result: anyerror!ConfigReload) !void {
    const reload = try result;
    switch (reload) {
        .unchanged => |mtime_ns| client.config_mtime_ns = mtime_ns,
        .failed => |failure| {
            client.config_diagnostic = failure.diagnostic;
            client.config_mtime_ns = failure.mtime_ns;
            try client.notifyDiagnostic("Configuration rejected");
        },
        .loaded => |loaded| {
            const snapshot = &loaded.generation.snapshot;
            const requested_sidebar = if (client.options.sidebar_renderer_locked)
                client.sidebar_rendering
            else
                snapshot.sidebar_rendering;
            _ = requested_sidebar.resolve(client.capabilities.kitty_graphics) catch |err| {
                client.config_diagnostic.set(
                    "reloaded sidebar renderer is unavailable: {s}",
                    .{@errorName(err)},
                );
                client.config_mtime_ns = loaded.mtime_ns;
                client.reload_generation_orphan = null;
                client.reload_registry_orphan = null;
                client.reload_trust_orphan = null;
                loaded.generation.deinit();
                client.gpa.destroy(loaded.registry);
                client.gpa.destroy(loaded.trust_store);
                try client.notifyDiagnostic("Configuration rejected");
                try client.scheduleConfigReload();
                return;
            };
            var replacement = buildInputRouter(
                snapshot.prefix,
                snapshot.bindingSlice(),
            ) catch |err| {
                client.config_diagnostic.set(
                    "reloaded keymap is invalid: {s}",
                    .{@errorName(err)},
                );
                client.config_mtime_ns = loaded.mtime_ns;
                client.reload_generation_orphan = null;
                client.reload_registry_orphan = null;
                client.reload_trust_orphan = null;
                loaded.generation.deinit();
                client.gpa.destroy(loaded.registry);
                client.gpa.destroy(loaded.trust_store);
                try client.notifyDiagnostic("Configuration rejected");
                try client.scheduleConfigReload();
                return;
            };
            replacement.escape_timeout_ns = snapshot.input_escape_timeout_ns;
            replacement.sequence_timeout_ns = snapshot.input_sequence_timeout_ns;

            client.input_router = replacement;
            if (!client.options.theme_locked) client.view.setTheme(snapshot.theme);
            client.sidebar_rendering = requested_sidebar;
            client.view.setSidebarVisible(snapshot.sidebar_visible);
            client.tabs.setPaneGaps(snapshot.pane_gaps);
            const cell_size = client.capabilities.cellSize(
                client.host_size.cols,
                client.host_size.rows,
            );
            try client.view.configureSidebar(
                client.sidebar_rendering,
                client.capabilities.kitty_graphics,
                cell_size.width,
                cell_size.height,
            );
            if (client.tabs.active()) |active|
                try client.resizeAttached(&active.model, client.view.workbench());

            const previous = client.lua_generation;
            client.lua_generation = loaded.generation;
            client.reload_generation_orphan = null;
            const previous_registry = client.plugin_registry;
            client.plugin_registry = loaded.registry;
            client.reload_registry_orphan = null;
            const previous_trust = client.trust_store;
            client.trust_store = loaded.trust_store;
            client.reload_trust_orphan = null;
            if (previous) |old| old.deinit();
            if (previous_registry) |old| client.gpa.destroy(old);
            if (previous_trust) |old| client.gpa.destroy(old);
            client.config_mtime_ns = loaded.mtime_ns;
            client.next_config_generation += 1;
            client.config_diagnostic.len = 0;
            try client.notify(.{
                .level = .success,
                .title = "Configuration reloaded",
                .message = "The new settings are active",
            });
        },
    }
    try client.scheduleConfigReload();
}

pub fn handlePluginResultEvent(
    client: *Client,
    result: anyerror!plugin_broker.WorkerResult,
) !bool {
    client.plugin_pending = false;
    const worker_result = result catch |err| {
        client.config_diagnostic.set("plugin worker failed: {s}", .{@errorName(err)});
        try client.notifyDiagnostic("Plugin failed");
        return false;
    };
    const registry = client.plugin_registry orelse {
        client.config_diagnostic.set("plugin registry changed while action was running", .{});
        try client.notifyDiagnostic("Plugin failed");
        return false;
    };
    registry.authorizeBatch(
        worker_result.package_index,
        worker_result.plugin_id,
        worker_result.digest,
        &worker_result.batch,
    ) catch |err| {
        client.config_diagnostic.set("plugin effect denied: {s}", .{@errorName(err)});
        try client.notifyDiagnostic("Plugin denied");
        return false;
    };
    client.config_diagnostic.len = 0;
    var handler: InputHandler = .{ .client = client };
    for (worker_result.batch.slice()) |effect|
        if (try handler.applyNativeAction(effect) == .stop) return true;
    if (handler.redraw) try client.requestDraw();
    return false;
}

/// Routes one decoded message from the runtime.
fn handleServerMessage(client: *Client, message: schema.ServerMessage) !?u8 {
    switch (message) {
        .pane_opened => |opened| try client.handlePaneOpened(opened),
        .tab_snapshot => |snapshot| try client.handleTabSnapshot(snapshot),
        .workspace_snapshot => |snapshot| try client.handleWorkspaceSnapshot(snapshot),
        .tab_created => |created| try client.handleTabCreated(created),
        .tab_renamed => |renamed| try client.handleTabRenamed(renamed),
        .tab_closed => |closed| return client.handleTabClosed(closed),
        .tab_moved => |moved| try client.handleTabMoved(moved),
        .pane_frame => |frame| try client.handlePaneFrame(frame),
        .pane_cwd => |cwd| try client.handlePaneCwd(cwd),
        .pane_clipboard => |clipboard| {
            if (clipboard.pane_id == .invalid) return error.UnexpectedPane;
            try term.writeClipboard(client.writer, clipboard.bytes);
            try client.writer.flush();
        },
        .pane_exited => |exited| try client.handlePaneExited(exited),
        .request_failed => |failure| try client.handleRequestFailed(failure),
        .notification => |notification| try client.notify(.{
            .level = switch (notification.level) {
                .info => .info,
                .success => .success,
                .warning => .warning,
                .failure => .failure,
            },
            .title = notification.title,
            .message = notification.message,
            .target = switch (notification.target) {
                .none => .none,
                .pane => |pane_id| .{ .focus_pane = pane_id },
                .tab => |tab_id| .{ .select_tab = tab_id },
                .workspace => |workspace_id| .{ .select_workspace = workspace_id },
            },
            .duration_ns = @as(u64, notification.duration_ms) * std.time.ns_per_ms,
        }),
        .notification_shown => |shown| {
            const continuation = client.requests.take(shown.request_id) orelse
                return error.UnexpectedNotificationReply;
            if (continuation != .notification) return error.UnexpectedNotificationReply;
            if (shown.delivered_clients == 0) try client.notify(.{
                .level = .failure,
                .title = "Notification not delivered",
                .message = "No connected client could accept the notification",
            });
        },
        .resync_required => |required| {
            switch (workspaceClosureAction(
                required.workspace_closed,
                required.previous_workspace,
            )) {
                .stay => try client.handleResyncRequired(required),
                .exit => return 0,
                .switch_to => |previous| {
                    var handler: InputHandler = .{ .client = client };
                    try handler.switchWorkspaceResolved(previous);
                    try client.requestDraw();
                    return null;
                },
            }
        },
        .runtime_stopping => return 0,
        .history_results => return error.UnexpectedHistoryResults,
        .proxy_status => |status| try client.handleProxyStatus(status),
        .agent_snapshot => |snapshot| try client.handleAgentSnapshot(snapshot),
        .system_metrics => |metrics| try client.handleSystemMetrics(metrics),
        .workspace_list => |list| try client.handleWorkspaceList(list),
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

fn handleProxyStatus(client: *Client, status: schema.ProxyStatus) !void {
    if (client.view.proxy_tls_active == status.active) return;
    client.view.setProxyTlsActive(status.active);
    try client.notify(.{
        .level = if (status.active) .warning else .info,
        .title = if (status.active) "TLS interception active" else "TLS interception stopped",
        .message = if (status.active)
            "Agent network traffic is being observed"
        else
            "Agent network traffic is no longer observed",
        .duration_ns = if (status.active)
            7 * std.time.ns_per_s
        else
            widgets.notification.default_duration_ns,
    });
}

fn handleAgentSnapshot(client: *Client, snapshot: schema.AgentSnapshotView) !void {
    var agents: [schema.max_agent_snapshot_entries]widgets.sidebar.AgentInput = undefined;
    var alerts: [widgets.notification.max_items]widgets.sidebar.AgentInput = undefined;
    var alert_count: usize = 0;
    var count: usize = 0;
    var iterator = snapshot.entries();
    while (try iterator.next()) |entry| {
        agents[count] = .{
            .key = .{
                .pane_id = entry.pane_id,
                .pane_generation = entry.pane_generation,
            },
            .provider = entry.provider,
            .status = entry.status,
        };
        const previous = client.view.sidebar_snapshot.find(agents[count].key);
        if (shouldNotifyAgentStatus(
            if (previous) |agent| agent.status else null,
            entry.status,
        ) and alert_count < alerts.len) {
            alerts[alert_count] = agents[count];
            alert_count += 1;
        }
        count += 1;
    }
    const replaced = try client.view.replaceSidebarSnapshot(.{
        .revision = snapshot.revision,
        .agents = agents[0..count],
    });
    if (replaced) {
        if (alert_count == 0) {
            try client.requestDraw();
        } else for (alerts[0..alert_count]) |agent| {
            var message_buffer: [64]u8 = undefined;
            const message = std.fmt.bufPrint(
                &message_buffer,
                "{s} in pane {d} is {s}",
                .{
                    agentProviderName(agent.provider),
                    schema.id.raw(agent.key.pane_id),
                    agentStatusName(agent.status),
                },
            ) catch "Agent status changed";
            try client.notify(.{
                .level = switch (agent.status) {
                    .blocked => .warning,
                    .ready => .success,
                    .failed => .failure,
                    else => unreachable,
                },
                .title = switch (agent.status) {
                    .blocked => "Agent needs input",
                    .ready => "Agent ready",
                    .failed => "Agent failed",
                    else => unreachable,
                },
                .message = message,
                .target = .{ .focus_pane = agent.key.pane_id },
                .duration_ns = if (agent.status == .failed)
                    7 * std.time.ns_per_s
                else
                    widgets.notification.default_duration_ns,
            });
        }
    }
    try client.scheduleSidebarAnimation();
}

fn handleSystemMetrics(client: *Client, metrics: schema.SystemMetrics) !void {
    client.view.setSystemMetrics(.{
        .cpu_percent = metrics.cpu_percent,
        .memory_used_decigib = metrics.memory_used_decigib,
        .battery_percent = if (metrics.has_battery) metrics.battery_percent else null,
    });
    try client.requestDraw();
}

fn handlePaneCwd(client: *Client, message: schema.PaneCwd) !void {
    const pane = client.tabs.findPane(message.pane_id) orelse return;
    if (!try pane.setCwd(message.cwd)) return;
    client.view.invalidate();
    try client.requestDraw();
}

fn handleWorkspaceList(client: *Client, list: schema.WorkspaceListView) !void {
    var entries: [schema.max_workspace_list_entries]widgets.workspace_model.EntryInput = undefined;
    var count: usize = 0;
    var iterator = list.entries();
    while (try iterator.next()) |entry| {
        entries[count] = .{
            .workspace = entry.workspace,
            .name = entry.name,
            .path = entry.path,
            .tab_count = entry.tab_count,
        };
        count += 1;
    }
    // A snapshot the fixed-capacity replica cannot hold is dropped rather
    // than fatal: the bar keeps showing the previous list, and the next
    // revision gets another chance.
    const replaced = client.view.replaceWorkspaceList(.{
        .revision = list.revision,
        .entries = entries[0..count],
    }) catch return;
    if (replaced) try client.requestDraw();
}

fn handlePaneOpened(client: *Client, opened: schema.PaneOpened) !void {
    const continuation = client.requests.take(opened.request_id) orelse
        return error.UnexpectedRequest;
    switch (continuation) {
        .initial_open => try client.bootstrapWorkspace(opened),
        .create_workspace => {
            if (!opened.created) return error.UnexpectedRequest;
            try client.clearPaneFocus();
            for (&client.tabs.items) |*slot| {
                const tab = if (slot.*) |*value| value else continue;
                for (&tab.model.panes) |*pane_slot| {
                    const pane = if (pane_slot.*) |*value| value else continue;
                    try client.graphics_store.setPaneVisible(pane.id, false);
                }
            }
            client.tabs.deinit();
            try client.bootstrapWorkspace(opened);
            try client.notify(.{
                .level = .success,
                .title = "Workspace created",
                .message = "The new workspace is ready",
            });
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
            try client.syncPaneFocus(model);
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

fn bootstrapWorkspace(client: *Client, opened: schema.PaneOpened) !void {
    if (client.tabs.count != 0) return error.UnexpectedRequest;
    try client.tabs.bootstrap(
        opened.pane_id,
        opened.location,
        rectSize(client.view.workbench()) orelse return error.TerminalTooSmall,
    );
    try client.syncPaneFocus(&client.tabs.active().?.model);
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
}

fn handleTabSnapshot(client: *Client, snapshot: schema.TabSnapshotView) !void {
    const continuation = client.requests.take(snapshot.request_id) orelse
        return error.UnexpectedTabSnapshot;
    if (continuation != .tab_snapshot or
        !std.meta.eql(continuation.tab_snapshot, snapshot.location))
        return error.UnexpectedTabSnapshot;
    const tab = try client.tabs.reconcileTab(snapshot, client.view.workbench());
    const model = &tab.model;
    if (client.tabs.active()) |active| try client.syncPaneFocus(&active.model);
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
    const expected_workspace = switch (continuation) {
        .workspace_snapshot => |workspace| workspace,
        .rename_workspace => |workspace| workspace,
        else => return error.UnexpectedWorkspaceSnapshot,
    };
    const renamed = continuation == .rename_workspace;
    if (!std.meta.eql(expected_workspace, snapshot.workspace))
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
        ) == null) releaseTabGraphics(&client.graphics_store, tab);
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
            } else {
                // A resync can mean the geometry lease was released.
                // Re-offer this client's sizes; the runtime adopts them
                // when the lease is free and ignores them otherwise.
                try client.resizeAttached(&active.model, client.view.workbench());
            }
        }
    }
    client.view.invalidate();
    if (renamed) {
        try client.notify(.{
            .level = .success,
            .title = "Workspace renamed",
            .message = "The workspace name was updated",
            .target = notificationTarget(continuation),
        });
    } else try client.requestDraw();
}

fn handleTabCreated(client: *Client, created: schema.TabCreated) !void {
    const continuation = client.requests.take(created.request_id) orelse
        return error.UnexpectedTabCreated;
    if (continuation != .create_tab or
        !std.meta.eql(continuation.create_tab, created.location.workspace))
        return error.UnexpectedTabCreated;
    if (client.tabs.active()) |current| {
        var handler: InputHandler = .{ .client = client };
        try client.clearPaneFocus();
        try handler.detachTab(current);
    }
    _ = try client.tabs.addCreated(
        created,
        rectSize(client.view.workbench()) orelse return error.TerminalTooSmall,
    );
    try client.syncPaneFocus(&client.tabs.active().?.model);
    client.view.invalidate();
    try client.notify(.{
        .level = .success,
        .title = "Tab created",
        .message = created.label,
        .target = .{ .select_tab = created.location.tab_id },
    });
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
    try client.notify(.{
        .level = .success,
        .title = "Tab renamed",
        .message = renamed.label,
        .target = .{ .select_tab = renamed.location.tab_id },
    });
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
    if (was_active) client.forgetPaneFocus();
    // The runtime sends no per-pane exit for a closed tab, so its
    // graphics would stay resident forever without this.
    if (client.tabs.find(closed.location.tab_id)) |closing|
        releaseTabGraphics(&client.graphics_store, closing);
    if (!client.tabs.remove(closed.location.tab_id)) {
        if (lifecycle_event) return null;
        return error.UnexpectedTab;
    }
    switch (workspaceClosureAction(closed.workspace_closed, closed.previous_workspace)) {
        .stay => {},
        .exit => return 0,
        .switch_to => |previous| {
            var handler: InputHandler = .{ .client = client };
            try handler.switchWorkspaceResolved(previous);
            try client.requestDraw();
            return null;
        },
    }
    if (client.tabs.count == 0) return error.WorkspaceHasNoTabs;
    if (was_active) {
        const active = client.tabs.active().?;
        try client.syncPaneFocus(&active.model);
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
    const previous_scroll_offset = pane.scroll.offset;
    const tab = client.tabs.tabForPane(frame.pane_id) orelse
        return error.UnexpectedPane;
    const applied = try tab.model.applyFrame(frame);
    const should_show_graphics = frame.scroll.atBottom(frame.rows) and
        client.tabs.active() != null and
        std.meta.eql(client.tabs.active().?.location, tab.location);
    if (client.graphics_store.paneVisible(frame.pane_id) != should_show_graphics)
        try client.graphics_store.setPaneVisible(frame.pane_id, should_show_graphics);
    if (client.copy_mode_state) |*state| {
        if (state.pane_id == frame.pane_id) {
            if (frame.scroll.offset < previous_scroll_offset and
                state.viewport_offset == previous_scroll_offset)
            {
                const pruned = previous_scroll_offset - frame.scroll.offset;
                state.cursor.y -|= pruned;
                if (state.anchor) |*anchor| anchor.y -|= pruned;
            }
            state.cursor.y = @min(state.cursor.y, frame.scroll.total_rows -| 1);
            if (state.anchor) |*anchor|
                anchor.y = @min(anchor.y, frame.scroll.total_rows -| 1);
            state.viewport_offset = frame.scroll.offset;
            const updated = tab.model.find(frame.pane_id).?;
            updated.copy_view = state.view();
            tab.model.composition_invalidated = true;
        }
    }
    if (comptime diagnostics.enabled) {
        client.metrics.frames += 1;
        client.metrics.frame_cells += applied.cells;
        client.metrics.frame_spans += applied.spans;
        if (frame.base_frame_id == 0) client.metrics.snapshots += 1;
        client.metrics.apply.observe(diagnostics.elapsed(apply_started, diagnostics.now(client.io)));
    }
    if (client.tabs.active()) |active| try client.syncPaneFocus(&active.model);
    try client.requestDraw();
}

fn handlePaneExited(client: *Client, exited: schema.PaneExited) !void {
    if (client.copy_mode_state) |state| {
        if (state.pane_id == exited.pane_id) client.copy_mode_state = null;
    }
    client.graphics_store.clearPane(exited.pane_id);
    const tab = client.tabs.tabForPane(exited.pane_id);
    const tab_id = if (tab) |value| value.location.tab_id else null;
    if (client.reported_focus == exited.pane_id) client.forgetPaneFocus();
    if (tab) |value| _ = value.model.removePane(exited.pane_id);
    client.view.invalidate();
    const requested = client.requests.completePaneClose(exited.pane_id);
    if (client.tabs.active()) |active| {
        try client.syncPaneFocus(&active.model);
        if (active.model.pane_count != 0)
            try client.resizeAttached(&active.model, client.view.workbench());
    }
    if (!requested) {
        try client.notify(.{
            .level = .warning,
            .title = "Pane exited",
            .message = "The process in this pane has stopped",
            .target = if (tab_id) |id| .{ .select_tab = id } else .none,
        });
    } else try client.requestDraw();
}

fn handleRequestFailed(client: *Client, failure: schema.RequestFailed) !void {
    const continuation = client.requests.take(failure.request_id) orelse {
        std.debug.print("telar runtime: {s}\n", .{failure.message});
        return error.UnexpectedRequestFailure;
    };
    switch (continuation) {
        .ignored, .close_pane, .rename_tab, .rename_workspace, .move_tab => {},
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
        .create_workspace, .notification => {},
        .initial_open, .workspace_snapshot, .tab_snapshot, .create_tab => {
            std.debug.print("telar runtime: {s}\n", .{failure.message});
            return error.RuntimeRequestFailed;
        },
    }
    if (continuation == .ignored) {
        try client.requestDraw();
    } else {
        try client.notify(.{
            .level = .failure,
            .title = failureTitle(continuation),
            .message = failure.message,
            .target = notificationTarget(continuation),
            .duration_ns = 7 * std.time.ns_per_s,
        });
    }
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
    if (comptime diagnostics.enabled) switch (message) {
        .graphics_image, .graphics_shared_image => client.metrics.graphics_images += 1,
        else => {},
    };
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
    const model = presentableModel(&client.tabs) orelse return;
    const presented_ns = try client.present(model);
    client.observePresentation(presented_ns);
    client.pacer.record(presented_ns, client.draw_due_ns, client.pending_updates);
    client.pending_updates = 0;
    // The graphics budget may have left work behind; the pacer turns
    // this into the next frame, not a spin.
    if ((client.graphics_store.damage or client.view.kittySidebar().damaged() or
        client.view.kittyToasts().damaged()) and
        client.capabilities.kitty_graphics == .supported)
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
    const media_idle = monotonic(client.io) -| client.last_input_ns >=
        kitty.idle_boost_after_ns;
    client.view.kittyToasts().setMediaIdle(media_idle);
    const compose_started = diagnostics.now(client.io);
    const composed = try model.renderThemed(&client.screen, client.view.workbench(), client.view.palette());
    const chrome = try client.view.render(&client.screen, &client.tabs, model, composed.full);
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
    client.graphics_store.host_zlib = client.capabilities.kitty_zlib == .supported;
    // Media rides the interactive writer, so its budget follows the user:
    // baseline while input is live, boosted once the host has been quiet.
    const media_budget = if (media_idle)
        kitty.transmission_budget_per_frame * kitty.idle_transmission_boost
    else
        kitty.transmission_budget_per_frame;
    var graphics_writer: CombinedGraphicsWriter = .{
        .panes = .{
            .store = &client.graphics_store,
            .layout_snapshot = layout_snapshot,
            .cell_width = cell_size.width,
            .cell_height = cell_size.height,
            .budget = media_budget,
        },
        .sidebar = client.view.kittySidebar(),
        .toasts = client.view.kittyToasts(),
        .allow_toast_transmission = media_idle,
        .metrics = &client.metrics,
    };
    if (client.capabilities.kitty_graphics == .supported) client.screen.graphics = .{
        .context = &graphics_writer,
        .write = CombinedGraphicsWriter.writeOpaque,
    };
    try flushScreen(client.io, &client.screen, client.writer, &client.metrics);
    if (comptime diagnostics.enabled) {
        const graphics_stats = graphics_writer.panes.stats;
        client.metrics.pane_shared_images += graphics_stats.shared_images;
        client.metrics.pane_inline_images += graphics_stats.inline_images;
        client.metrics.pane_compressed_images += graphics_stats.compressed_images;
        client.metrics.pane_transmission_passes += graphics_stats.transmission_passes;
        client.metrics.pane_compress_passes += graphics_stats.compress_passes;
    }
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

pub fn resizeAttached(client: *Client, model: *multiplexer.Model, area: ui.Rect) !void {
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


pub fn buildInputRouter(prefix: keybind.Key, configured: []const ConfiguredBinding) !InputRouter {
    const resolved = try lua_config.resolveBindings(prefix, configured);
    return InputRouter.init(resolved.slice());
}

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
pub fn presentableModel(tabs: *tabs_mod.Model) ?*multiplexer.Model {
    const active = tabs.active() orelse return null;
    return &active.model;
}

fn scheduleInputTimers(client: *Client) !void {
    if (!client.input_timeout_pending) {
        if (client.input_router.inputDeadline()) |deadline| {
            client.input_timeout_pending = true;
            client.select.concurrent(.input_timeout, waitUntil, .{ client.io, deadline }) catch |err| {
                client.input_timeout_pending = false;
                return err;
            };
        }
    }
    if (!client.binding_timeout_pending) {
        if (client.input_router.bindingDeadline()) |deadline| {
            client.binding_timeout_pending = true;
            client.select.concurrent(.binding_timeout, waitUntil, .{ client.io, deadline }) catch |err| {
                client.binding_timeout_pending = false;
                return err;
            };
        }
    }
}

fn waitUntil(io: Io, deadline_ns: u64) anyerror!void {
    const deadline = Io.Timestamp.fromNanoseconds(@intCast(deadline_ns)).withClock(.awake);
    try deadline.wait(io);
}

fn waitForNotificationTick(io: Io, timer: *NotificationTimer) anyerror!void {
    while (true) {
        const deadline_ns = timer.deadline_ns.load(.acquire);
        if (monotonic(io) >= deadline_ns) return;
        switch (try waitForNotificationTimerEvent(io, timer, deadline_ns)) {
            .deadline => return,
            .rescheduled => timer.wake.reset(),
        }
    }
}

fn waitForNotificationTimerEvent(
    io: Io,
    timer: *NotificationTimer,
    deadline_ns: u64,
) anyerror!NotificationTimerResult {
    var storage: [2]NotificationTimerEvent = undefined;
    var select = Io.Select(NotificationTimerEvent).init(io, &storage);
    defer select.cancelDiscard();
    try select.concurrent(.deadline, waitUntil, .{ io, deadline_ns });
    try select.concurrent(.rescheduled, waitForNotificationReschedule, .{ io, &timer.wake });
    return switch (try select.await()) {
        .deadline => |result| blk: {
            try result;
            break :blk .deadline;
        },
        .rescheduled => |result| blk: {
            try result;
            break :blk .rescheduled;
        },
    };
}

fn waitForNotificationReschedule(io: Io, event: *Io.Event) anyerror!void {
    try event.wait(io);
}

pub fn waitResize(io: Io, watcher: *platform.ResizeWatcher) anyerror!void {
    return watcher.wait(io);
}

pub fn receive(io: Io, connection: *core.transport.SocketChannel, buffer: []u8) anyerror![]u8 {
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
    toasts: *toast_graphics.Renderer,
    allow_toast_transmission: bool,
    metrics: *ClientMetrics,

    fn writeOpaque(context: *anyopaque, writer: *Io.Writer) Io.Writer.Error!usize {
        const self: *CombinedGraphicsWriter = @ptrCast(@alignCast(context));
        const pane_bytes = try self.panes.write(writer);
        // An open budget-paced transfer owns the graphics stream. Toast
        // deletions and placements remain cheap, while a new toast texture
        // waits for an otherwise-idle pane-media pass.
        var toast_bytes: usize = 0;
        if (self.panes.store.partial == null)
            toast_bytes = try self.toasts.write(
                writer,
                pane_bytes == 0 and self.allow_toast_transmission,
            );
        var sidebar_bytes: usize = 0;
        if (self.panes.store.partial == null and toast_bytes == 0)
            sidebar_bytes = try self.sidebar.write(writer);
        if (comptime diagnostics.enabled) {
            self.metrics.pane_graphics_flushed_bytes += pane_bytes;
            self.metrics.sidebar_graphics_flushed_bytes += sidebar_bytes;
        }
        return pane_bytes + toast_bytes + sidebar_bytes;
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

pub fn waitCapabilityTimeout(io: Io) anyerror!void {
    const now = monotonic(io);
    const deadline = Io.Timestamp.fromNanoseconds(@intCast(now + kitty.capability_timeout_ns)).withClock(.awake);
    try deadline.wait(io);
}

pub fn monotonic(io: Io) u64 {
    const timestamp = Io.Timestamp.now(io, .awake);
    return @intCast(@max(timestamp.nanoseconds, 0));
}

pub fn terminalSize(tty: *const platform.Tty) schema.TerminalSize {
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

test "workspace closure exits only when no predecessor survives" {
    try std.testing.expectEqualDeep(
        WorkspaceClosureAction.stay,
        workspaceClosureAction(false, null),
    );
    try std.testing.expectEqualDeep(
        WorkspaceClosureAction.exit,
        workspaceClosureAction(true, null),
    );
    try std.testing.expectEqualDeep(
        WorkspaceClosureAction{ .switch_to = @enumFromInt(7) },
        workspaceClosureAction(true, @enumFromInt(7)),
    );
}

test "agent notifications report only actionable status transitions" {
    try std.testing.expect(!shouldNotifyAgentStatus(null, .blocked));
    try std.testing.expect(!shouldNotifyAgentStatus(.working, .working));
    try std.testing.expect(!shouldNotifyAgentStatus(.ready, .working));
    try std.testing.expect(shouldNotifyAgentStatus(.working, .blocked));
    try std.testing.expect(shouldNotifyAgentStatus(.working, .ready));
    try std.testing.expect(shouldNotifyAgentStatus(.working, .failed));
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

