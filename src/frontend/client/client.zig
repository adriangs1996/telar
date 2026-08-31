//! One attached client: the long-lived objects `run` owns by pointer, plus
//! every piece of pending-request and frame-pacing state that used to be a
//! loose local threaded through fourteen-argument calls.

const std = @import("std");
const core = @import("telar-core");
const input_capability = @import("../input/root.zig");
const presentation = @import("../presentation/root.zig");
const workspace_capability = @import("../workspace/root.zig");
const graphics = @import("../graphics/root.zig");
const attachments = @import("../attachments/root.zig");
const action_mod = input_capability.action;
const client_outbox = @import("outbox.zig");
const client_requests = @import("requests.zig");
const client_telemetry = @import("telemetry.zig");
const client_view = @import("view.zig");
const client_model = @import("model.zig");
const notification_capability = @import("../notifications/root.zig");
const lua_config = @import("../config/root.zig");
const sound_mod = @import("../sound.zig");
const input_mod = input_capability.host;
const keybind = input_capability.keybind;
const mouse_protocol = input_capability.mouse_protocol;
const kitty = graphics.kitty;
const toast_graphics = graphics.toast;
const layout_mod = workspace_capability.layout;
const multiplexer = workspace_capability.multiplexer;
const navigation = workspace_capability.navigation;
const tabs_mod = workspace_capability.tabs;
const pace = presentation.pace;
const term = presentation.screen;
const platform = @import("../platform/root.zig");
const plugin_broker = @import("../plugins/root.zig");
const ui_capability = @import("../ui/root.zig");
const icons = ui_capability.icons;
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
    icon_theme: icons.Theme = .unicode,
    sidebar_rendering: kitty.SidebarRendering = .automatic,
    sidebar_visible: bool = true,
    pane_gaps: bool = true,
    sound: lua_config.SoundConfig = .{},
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

pub const InputChunk = struct {
    bytes: [input_chunk_size]u8 = undefined,
    len: u16 = 0,

    fn slice(chunk: *const InputChunk) []const u8 {
        return chunk.bytes[0..chunk.len];
    }
};
const InputHandler = @import("input_handler.zig");
const config_reload = @import("config_reload.zig");
const notification_flow = @import("notifications.zig");
const presenter_mod = @import("presenter.zig");
const server_messages = @import("server_messages.zig");

pub const ClientEvent = union(enum) {
    input: anyerror!InputChunk,
    input_timeout: anyerror!void,
    binding_timeout: anyerror!void,
    capability_timeout: anyerror!void,
    resized: anyerror!void,
    server: anyerror![]u8,
    sent: anyerror!void,
    draw: anyerror!void,
    media_tick: anyerror!void,
    sidebar_animation_tick: anyerror!void,
    notification_tick: anyerror!void,
    sound_played: anyerror!void,
    telemetry_tick: anyerror!void,
    telemetry_written: anyerror!void,
    config_reload: anyerror!config_reload.ConfigReload,
    plugin_result: anyerror!plugin_broker.WorkerResult,
    clipboard_image: anyerror!*attachments.Capture,
};

const NotificationTimer = struct {
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

/// The request that opens the first pane; everything else is numbered by
/// `Client.nextId`.
pub const initial_request_id: schema.RequestId = @enumFromInt(1);

const client_event_count = @typeInfo(ClientEvent).@"union".fields.len;

/// The platform resources a client cannot fabricate: everything else it
/// owns. Substituting these — a pipe for the tty's read handle, a
/// fixed-buffer writer, a scripted socket peer — is what makes the client
/// constructible in a test.
const Params = struct {
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
presenter: presenter_mod,
view: client_view.State,
model: client_model.Model,
navigation_history: navigation.History = .{},
graphics_store: kitty.Store,
capabilities: kitty.TerminalCapabilities,
host_size: schema.TerminalSize,
input_file: File,
input_router: InputRouter,
input_timeout_pending: bool = false,
binding_timeout_pending: bool = false,
telemetry_buffer: [8192]u8 = undefined,
telemetry_write_pending: bool = false,
lua_generation: ?*lua_config.Generation,
config_diagnostic: lua_config.Diagnostic = .{},
plugin_registry: ?*plugin_broker.Registry,
trust_store: ?*core.plugin.TrustStore,
reload: config_reload.State,
sidebar_rendering: kitty.SidebarRendering,
sound_config: lua_config.SoundConfig,
plugin_pending: bool = false,
attachment_capture: attachments.CaptureState = .{},
paste_pane: ?schema.PaneId = null,

input_read_pending: bool = false,
next_request_id: u64 = 2,
requests: client_requests.Tracker = .{},
sidebar_animation_pending: bool = false,
notification_tick_pending: bool = false,
notification_timer: NotificationTimer = .{},
sound_pending: bool = false,
queued_sound: ?sound_mod.Kind = null,
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
    var view = try client_view.State.initWithAppearance(
        gpa,
        host_size.cols,
        host_size.rows,
        params.options.theme,
        params.options.icon_theme,
    );
    errdefer view.deinit();
    view.setSidebarVisible(params.options.sidebar_visible);
    try view.configureSidebar(
        params.options.sidebar_rendering,
        capabilities.kitty_graphics,
        cell_size.width,
        cell_size.height,
    );
    var model = client_model.Model.init(gpa, params.options.pane_gaps);
    errdefer model.deinit();
    _ = model.setSidebarVisible(params.options.sidebar_visible);
    var graphics_store = if (params.options.host_shared_memory)
        kitty.Store.initSharedMemory(gpa)
    else
        kitty.Store.init(gpa);
    errdefer graphics_store.deinit();
    const receive_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    errdefer gpa.free(receive_buffer);
    const send_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    errdefer gpa.free(send_buffer);
    var input_router = try config_reload.buildInputRouter(params.options.prefix, params.options.bindings);
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
        .presenter = undefined,
        .view = view,
        .model = model,
        .graphics_store = graphics_store,
        .capabilities = capabilities,
        .host_size = host_size,
        .input_file = params.input_file,
        .input_router = input_router,
        .lua_generation = params.options.lua_generation,
        .plugin_registry = params.options.plugin_registry,
        .trust_store = params.options.trust_store,
        .sidebar_rendering = params.options.sidebar_rendering,
        .sound_config = params.options.sound,
        .reload = .{ .mtime_ns = params.options.config_mtime_ns },
    };
    // The select's storage lives inside the heap-stable client, so the
    // select can only be built once the client's address exists.
    client.select = Io.Select(ClientEvent).init(params.io, &client.select_storage);
    // The presenter borrows the select and metrics, whose heap addresses
    // only exist once the client does.
    client.presenter = .{
        .io = params.io,
        .select = &client.select,
        .metrics = &client.metrics,
        .screen = screen,
    };
    return client;
}

/// Cancels every in-flight select task first — the reload task publishes
/// into the orphan slots — then releases the orphans, the owned
/// configuration objects, and every buffer.
pub fn deinit(client: *Client) void {
    const gpa = client.gpa;
    client.select.cancelDiscard();
    client.reload.deinit(gpa);
    client.attachment_capture.deinit(gpa);
    if (client.lua_generation) |generation| generation.deinit();
    if (client.plugin_registry) |registry| gpa.destroy(registry);
    if (client.trust_store) |store| gpa.destroy(store);
    client.graphics_store.deinit();
    client.model.deinit();
    client.view.deinit();
    client.presenter.deinit();
    gpa.free(client.send_buffer);
    gpa.free(client.receive_buffer);
    gpa.destroy(client);
}

pub fn nextId(client: *Client) !schema.RequestId {
    return nextRequestId(&client.next_request_id);
}

/// Publishes the model version after one client event has committed.
///
/// ```zig
/// try client.observeModel();
/// ```
pub fn observeModel(client: *Client) !void {
    try client.presenter.observeModel(client.model.version());
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

pub fn enqueueCreateWorkspaceRequest(client: *Client, request: schema.CreateWorkspace) !void {
    try client.requests.add(request.request_id, .{ .create_workspace = request.size });
    errdefer _ = client.requests.take(request.request_id);
    try client.outbox.pushCreateWorkspace(request);
    try client.pumpOutbox();
}

pub fn enqueueCreateTabRequest(client: *Client, request: schema.CreateTab) !void {
    try client.requests.add(request.request_id, .{ .create_tab = .{
        .workspace = request.workspace,
        .size = request.size,
    } });
    errdefer _ = client.requests.take(request.request_id);
    try client.outbox.pushCreateTab(request);
    try client.pumpOutbox();
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
    const payload = try client.outbox.beginSend(client.send_buffer) orelse return;
    client.select.concurrent(.sent, sendClient, .{
        client.io,
        client.connection,
        payload,
    }) catch |err| {
        client.outbox.sendFailed();
        return err;
    };
}

pub fn returnGraphicsCredits(client: *Client) !void {
    while (client.graphics_store.peekCredit()) |credit| {
        client.outbox.push(.{ .graphics_credit = .{
            .pane_id = credit.pane_id,
            .bytes = @intCast(credit.bytes),
        } }) catch break;
        client.graphics_store.consumeCredit(credit);
    }
    try client.pumpOutbox();
}

pub fn scheduleInputRead(client: *Client) !void {
    if (client.input_read_pending or !client.outbox.hasCapacity()) return;
    try client.select.concurrent(.input, readInput, .{ client.io, client.input_file });
    client.input_read_pending = true;
}

pub fn scheduleSidebarAnimation(client: *Client) !void {
    if (client.sidebar_animation_pending or !client.model.hasWorkingAgent()) {
        return;
    }
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

pub fn notify(client: *Client, input: notification_capability.Input) !void {
    _ = try notification_flow.publish(client, monotonic(client.io), input);
}

pub fn notifyDiagnostic(client: *Client, title: []const u8) !void {
    try client.notify(.{
        .level = .failure,
        .title = title,
        .message = client.config_diagnostic.message(),
        .duration_ns = 7 * std.time.ns_per_s,
    });
}

pub fn scheduleNotificationTick(client: *Client) !void {
    const now_ns = monotonic(client.io);
    const deadline_ns = client.model.nextNotificationDeadline(
        now_ns,
        client.presenter.pacer.interval,
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
    const pane = client.model.workspace.findPane(pane_id) orelse return;
    if (pane.attached) try client.enqueueInput(pane_id, "\x1b[O");
}

pub fn forgetPaneFocus(client: *Client) void {
    client.reported_focus = null;
    client.reported_focus_events = false;
}

/// Synchronizes a committed sidebar preference with disposable view,
/// graphics and runtime geometry resources.
///
/// ```zig
/// try client.syncSidebarVisibility(change);
/// ```
pub fn syncSidebarVisibility(client: *Client, change: client_model.SidebarVisibility) !void {
    if (client.model.sidebarVisible() != change.visible or
        client.model.version().chrome != change.chrome_revision)
    {
        return error.UnexpectedSidebarVisibility;
    }

    client.view.setSidebarVisible(change.visible);
    client.graphics_store.invalidatePlacements();
    const active = client.model.workspace.active() orelse return;

    try client.resizeAttached(&active.model, client.view.workbench());
}

pub fn syncPaneFocus(client: *Client, model: *multiplexer.Model) !void {
    if (client.view.syncAttachmentTarget(client.focusedAttachmentTarget())) {
        try client.resizeAttached(model, client.view.workbench());
    }
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

/// Resolves the model's focused attachment-capable agent into the local
/// preview identity used by platform and view adapters.
///
/// ```zig
/// const target = client.focusedAttachmentTarget() orelse return;
/// ```
pub fn focusedAttachmentTarget(client: *const Client) ?attachments.Target {
    const key = client.model.focusedAttachmentAgent() orelse return null;

    return .{
        .pane_id = key.pane_id,
        .pane_generation = key.pane_generation,
    };
}

/// Reconciles attachment resources after an agent snapshot commit. Any shelf
/// geometry change is applied to the currently active pane model.
///
/// ```zig
/// try client.syncAgentSnapshotResources();
/// ```
pub fn syncAgentSnapshotResources(client: *Client) !void {
    const layout_changed = client.view.syncAttachmentTarget(client.focusedAttachmentTarget());
    if (!layout_changed) {
        return;
    }

    const active = client.model.workspace.active() orelse return;
    try client.resizeAttached(&active.model, client.view.workbench());
}

pub fn scheduleAttachmentCapture(client: *Client, target: attachments.Target) !void {
    if (!attachments.platformSupported()) return;
    const request = (try client.attachment_capture.begin(target)) orelse return;
    client.select.concurrent(.clipboard_image, attachments.captureClipboard, .{
        client.gpa,
        request,
        &client.attachment_capture.orphan,
    }) catch |err| {
        client.attachment_capture.scheduleFailed();
        return err;
    };
}

pub fn handleClipboardImageEvent(
    client: *Client,
    result: anyerror!*attachments.Capture,
) !void {
    const completed = result catch |err| {
        client.attachment_capture.failed();
        switch (err) {
            error.NoImageOnClipboard => {},
            error.ClipboardImageTooLarge => try client.notify(.{
                .level = .failure,
                .title = "Image preview skipped",
                .message = "The clipboard image exceeds Telar's local preview limit",
            }),
            else => try client.notify(.{
                .level = .failure,
                .title = "Image preview failed",
                .message = @errorName(err),
            }),
        }
        return;
    };
    const capture = client.attachment_capture.take(completed);
    const active = client.model.workspace.active() orelse {
        capture.deinit(client.gpa);
        return;
    };
    const target = client.focusedAttachmentTarget() orelse {
        capture.deinit(client.gpa);
        return;
    };
    if (!std.meta.eql(target, capture.request.target)) {
        capture.deinit(client.gpa);
        return;
    }
    const layout_changed = client.view.adoptAttachment(capture) catch |err| {
        capture.deinit(client.gpa);
        try client.notify(.{
            .level = .failure,
            .title = "Image preview failed",
            .message = @errorName(err),
        });
        return;
    };
    if (layout_changed) try client.resizeAttached(&active.model, client.view.workbench());
    try client.presenter.requestDraw();
}

/// Entrypoint for bytes read from the host terminal. It owns the complete
/// routing decision: consume a Telar action or enqueue pane input.
pub fn handleHostInput(client: *Client, result: anyerror!InputChunk) !bool {
    client.input_read_pending = false;
    const chunk = try result;
    if (chunk.len == 0) return true;
    client.presenter.noteInput(monotonic(client.io));
    var handler: InputHandler = .{ .client = client };
    const prefix_was_pending = client.input_router.prefixPending();
    if (try client.input_router.feed(chunk.slice(), monotonic(client.io), &handler) == .stop)
        return true;
    client.syncPrefixStatus(prefix_was_pending, &handler);
    if (handler.redraw) try client.presenter.requestDraw();
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
    const status = server_messages.handleServerMessage(client, message) catch |err| {
        switch (message) {
            .request_failed => |failure| std.debug.print("telar runtime: {s}\n", .{failure.message}),
            else => {},
        }

        return err;
    };

    if (status) |exit_status| {
        return exit_status;
    }

    try client.returnGraphicsCredits();
    try client.select.concurrent(.server, receive, .{
        client.io,
        client.connection,
        client.receive_buffer,
    });
    return null;
}

/// Entrypoint for the escape-sequence input timeout: flush what the router held.
pub fn handleInputTimeoutEvent(client: *Client, result: anyerror!void) !bool {
    try result;
    client.input_timeout_pending = false;
    var handler: InputHandler = .{ .client = client };
    const prefix_was_pending = client.input_router.prefixPending();
    if (try client.input_router.expireInput(monotonic(client.io), &handler) == .stop) return true;
    client.syncPrefixStatus(prefix_was_pending, &handler);
    if (handler.redraw) try client.presenter.requestDraw();
    try client.scheduleInputTimers();
    return false;
}

/// Entrypoint for the binding-sequence timeout: replay an unfinished chord.
pub fn handleBindingTimeoutEvent(client: *Client, result: anyerror!void) !bool {
    try result;
    client.binding_timeout_pending = false;
    var handler: InputHandler = .{ .client = client };
    const prefix_was_pending = client.input_router.prefixPending();
    if (try client.input_router.expireBinding(monotonic(client.io), &handler) == .stop) return true;
    client.syncPrefixStatus(prefix_was_pending, &handler);
    if (handler.redraw) try client.presenter.requestDraw();
    try client.scheduleInputTimers();
    return false;
}

/// Entrypoint for the capability-probe deadline: settle what the host never answered.
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
    var tabs = client.model.workspace.tabIterator();
    while (tabs.next()) |tab| {
        var panes = tab.model.paneIterator();
        while (panes.next()) |pane| {
            tab.model.setGraphicsPlaceholder(
                pane.id,
                client.graphics_store.hasPaneGraphics(pane.id),
            );
        }
    }
    client.view.invalidate();
    try client.presenter.requestDraw();
}

/// Entrypoint for a host terminal resize: remeasure, reflow, and re-offer sizes.
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
    try client.presenter.resize(client.host_size.cols, client.host_size.rows);
    try client.view.resize(client.host_size.cols, client.host_size.rows);
    if (client.model.workspace.active()) |active| {
        active.model.setCellSize(cell_size.width, cell_size.height);
        client.graphics_store.invalidatePlacements();
        try client.resizeAttached(&active.model, client.view.workbench());
    }
    // Pixel dimensions can change independently when the font or display
    // scale changes. Refresh both values without blocking the resize path.
    try client.writer.writeAll("\x1b[14t\x1b[16t");
    try client.writer.flush();
    try client.presenter.requestDraw();
    try client.select.concurrent(.resized, waitResize, .{ client.io, watcher });
}

/// Entrypoint for one completed socket send: pop it and pump the next.
pub fn handleSentEvent(client: *Client, result: anyerror!void) !void {
    try result;
    client.outbox.popSent();
    try client.returnGraphicsCredits();
    try client.scheduleInputRead();
}

/// Entrypoint for the paced draw deadline.
pub fn handleDrawEvent(client: *Client, result: anyerror!void) !void {
    try result;
    try client.presenter.presentDue(client);
}

/// Entrypoint for the lower-priority, byte-bounded host graphics pass.
pub fn handleMediaTickEvent(client: *Client, result: anyerror!void) !void {
    try result;
    try client.presenter.presentMedia(client);
}

/// Entrypoint for the sidebar animation tick.
pub fn handleSidebarAnimationEvent(client: *Client, result: anyerror!void) !void {
    try result;
    client.sidebar_animation_pending = false;
    if (client.model.hasWorkingAgent()) {
        _ = client.view.advanceSidebarAnimation();
        try client.presenter.requestDraw();
    }
    try client.scheduleSidebarAnimation();
}

/// Entrypoint for the notification timer: advance and rearm.
pub fn handleNotificationTickEvent(client: *Client, result: anyerror!void) !void {
    try result;
    client.notification_tick_pending = false;
    _ = try notification_flow.advance(client, monotonic(client.io));
}

pub fn scheduleAgentSound(client: *Client, kind: sound_mod.Kind) !void {
    if (!client.sound_config.allows(kind)) return;
    if (client.sound_pending) {
        client.queued_sound = sound_mod.coalesce(client.queued_sound, kind);
        return;
    }
    client.sound_pending = true;
    client.select.concurrent(.sound_played, sound_mod.play, .{ client.io, kind }) catch |err| {
        client.sound_pending = false;
        return err;
    };
}

pub fn handleSoundPlayedEvent(client: *Client, result: anyerror!void) !void {
    _ = result catch {};
    client.sound_pending = false;
    const queued = client.queued_sound;
    client.queued_sound = null;
    if (queued) |kind| try client.scheduleAgentSound(kind);
}

pub fn handleTelemetryTickEvent(
    client: *Client,
    result: anyerror!void,
    telemetry: *diagnostics.Sink,
    heap: diagnostics.Heap.Snapshot,
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
    const active = client.model.workspace.active() orelse return;
    const focused = active.model.layout.focused() orelse .invalid;
    const line = client_telemetry.format(
        &client.telemetry_buffer,
        client.io,
        &client.metrics,
        &client.presenter.pacer,
        .{
            .theme_name = client.view.theme.base.canonicalName(),
            .icon_theme_name = client.view.icon_theme.canonicalName(),
            .active_tab = active.location.tab_id,
            .tab_count = client.model.workspace.count,
            .focused_pane = focused,
            .pane_count = active.model.pane_count,
            .pending_updates = client.presenter.pending_updates,
            .draw_pending = client.presenter.draw_pending,
            .media_pending = client.presenter.media_tick_pending,
            .outbox = &client.outbox,
            .capabilities = &client.capabilities,
            .sidebar_rendering = client.view.sidebar_rendering,
            .lua_used = if (client.lua_generation) |generation| generation.vm.meter.used else 0,
            .lua_limit = if (client.lua_generation) |generation| generation.vm.meter.limit else 0,
            .kitty_store_bytes = client.graphics_store.total_bytes,
            .toast_cache_bytes = client.view.kittyToasts().retainedBytes(),
            .sidebar_cache_bytes = client.view.kittySidebar().retainedBytes(),
            .icon_cache_bytes = client.view.kittyIcons().retainedBytes(),
            .modal_cache_bytes = client.view.kittyModal().retainedBytes(),
            .attachment_cache_bytes = client.view.kittyAttachments().retainedBytes(),
            .screen_bytes = (client.presenter.screen.front.cells.len +
                client.presenter.screen.back.cells.len) *
                @sizeOf(core.ui.Cell),
            .heap = heap,
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

/// Asks the runtime for a fresh snapshot of one tab, tracking the reply.
pub fn requestTabSnapshot(client: *Client, location: schema.TabLocation) !void {
    const request_id = try client.nextId();
    try client.enqueueRequest(
        request_id,
        .{ .tab_snapshot = location },
        .{ .request_tab_snapshot = .{
            .request_id = request_id,
            .location = location,
        } },
    );
}

/// Asks the runtime for a fresh snapshot of one workspace, tracking the
/// reply.
pub fn requestWorkspaceSnapshot(client: *Client, workspace: schema.WorkspaceLocation) !void {
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

/// Schedules one plugin action on the worker; its result re-enters the
/// loop as a `.plugin_result` event. The only place a plugin task starts.
pub fn schedulePluginAction(client: *Client, request: plugin_broker.WorkerRequest) !void {
    try client.select.concurrent(
        .plugin_result,
        plugin_broker.executeWorker,
        .{ client.io, client.gpa, request },
    );
    client.plugin_pending = true;
}

pub fn scheduleConfigReload(client: *Client) !void {
    const path = client.options.config_path orelse return;
    try config_reload.schedule(&client.reload, client.io, client.gpa, &client.select, .{
        .path = path,
        .profile = client.options.profile,
        .trust_path = client.options.trust_path.?,
        .current_generation = client.lua_generation.?,
        .current_registry = client.plugin_registry.?,
    });
}

/// Entrypoint for one finished reload attempt: adopt the new
/// configuration, surface the rejection, or note nothing changed — then
/// keep watching.
pub fn handleConfigReloadEvent(client: *Client, result: anyerror!config_reload.ConfigReload) !void {
    const reload = try result;
    switch (config_reload.resolve(&client.reload, client.gpa, reload, .{
        .kitty_support = client.capabilities.kitty_graphics,
        .sidebar_renderer_locked = client.options.sidebar_renderer_locked,
        .current_sidebar = client.sidebar_rendering,
    })) {
        .unchanged => {},
        .rejected => |diagnostic| {
            client.config_diagnostic = diagnostic;
            try client.notifyDiagnostic("Configuration rejected");
        },
        .adopted => |adoption| try client.applyConfig(adoption),
    }
    try client.scheduleConfigReload();
}

/// Applies an adopted configuration: the compiled router, the view-facing
/// settings, and the ownership swap of the generation, registry and trust
/// store. Everything loadable was already validated by the reload module.
pub fn applyConfig(client: *Client, adoption: config_reload.Adoption) !void {
    const snapshot = &adoption.generation.snapshot;
    client.input_router = adoption.router;
    if (!client.options.theme_locked) client.view.setTheme(snapshot.theme);
    client.view.setIconTheme(snapshot.icon_theme);
    client.sidebar_rendering = adoption.sidebar_rendering;
    const sidebar_change = client.model.setSidebarVisible(snapshot.sidebar_visible);
    client.view.setSidebarVisible(snapshot.sidebar_visible);
    if (sidebar_change != null) {
        client.graphics_store.invalidatePlacements();
    }
    client.model.workspace.setPaneGaps(snapshot.pane_gaps);
    client.sound_config = snapshot.sound;
    if (!client.sound_config.enabled) client.queued_sound = null;
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
    if (client.model.workspace.active()) |active|
        try client.resizeAttached(&active.model, client.view.workbench());

    const previous = client.lua_generation;
    client.lua_generation = adoption.generation;
    const previous_registry = client.plugin_registry;
    client.plugin_registry = adoption.registry;
    const previous_trust = client.trust_store;
    client.trust_store = adoption.trust_store;
    if (previous) |old| old.deinit();
    if (previous_registry) |old| client.gpa.destroy(old);
    if (previous_trust) |old| client.gpa.destroy(old);
    client.config_diagnostic.len = 0;
    try client.notify(.{
        .level = .success,
        .title = "Configuration reloaded",
        .message = "The new settings are active",
    });
}

/// Entrypoint for one finished plugin action: authorize and apply its effects.
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
    if (handler.redraw) try client.presenter.requestDraw();
    return false;
}

/// Re-offers this client's pane sizes to the runtime for every attached
/// pane of one model.
pub fn resizeAttached(client: *Client, model: *multiplexer.Model, area: ui.Rect) !void {
    var panes = model.paneIterator();
    while (panes.next()) |pane| {
        if (!pane.attached) continue;
        const size = model.contentSize(pane.id, area) orelse continue;
        try client.enqueue(.{ .pane_resize = .{
            .pane_id = pane.id,
            .size = size,
        } });
    }
}

fn readInput(io: Io, input: File) anyerror!InputChunk {
    var chunk: InputChunk = .{};
    chunk.len = @intCast(try input.readStreaming(io, &.{&chunk.bytes}));
    return chunk;
}

/// The model a due draw should present, or null while the client is not
/// presentable yet. Unwrapping the active tab here used to panic when a
/// resize arrived before the runtime answered the initial open request.
pub fn presentableModel(tabs: *tabs_mod.Model) ?*multiplexer.Model {
    const active = tabs.active() orelse return null;
    return &active.model;
}

pub fn statusMode(client: *const Client) widgets.status_bar.Mode {
    if (client.input_router.prefixPending()) {
        const DescribedAction = struct {
            action: Action,
            label: []const u8,
        };
        const useful = [_]DescribedAction{
            .{ .action = .{ .split_pane = .horizontal }, .label = "split right" },
            .{ .action = .{ .split_pane = .vertical }, .label = "split down" },
            .{ .action = .new_tab, .label = "new tab" },
            .{ .action = .new_workspace, .label = "new workspace" },
            .{ .action = .rename_tab, .label = "rename tab" },
            .{ .action = .rename_workspace, .label = "rename workspace" },
            .{ .action = .close_pane, .label = "close pane" },
            .{ .action = .enter_copy_mode, .label = "copy mode" },
        };
        var hints: widgets.status_bar.Hints = .{};
        for (useful) |described| {
            const key = client.input_router.prefixedKeyForAction(described.action) orelse
                continue;
            hints.append(.{ .key = key, .label = described.label });
        }
        return .{ .prefix = hints };
    }
    return if (client.model.copyModeActive()) .copy else .normal;
}

fn syncPrefixStatus(
    client: *Client,
    prefix_was_pending: bool,
    handler: *InputHandler,
) void {
    if (prefix_was_pending == client.input_router.prefixPending()) return;
    client.view.invalidate();
    handler.redraw = true;
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

fn writeDiagnostics(io: Io, sink: *diagnostics.Sink, bytes: []const u8) anyerror!void {
    try sink.write(io, bytes);
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
