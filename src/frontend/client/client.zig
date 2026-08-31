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
const client_outbox = @import("outbox.zig");
const client_requests = @import("requests.zig");
const client_telemetry = @import("telemetry.zig");
const client_view = @import("view.zig");
const client_model = @import("model.zig");
const notification_capability = @import("../notifications/root.zig");
const lua_config = @import("../config/root.zig");
const sound_capability = @import("../sound/root.zig");
const keybind = input_capability.keybind;
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

const Io = std.Io;
const File = Io.File;
const schema = core.schema;
const diagnostics = core.diagnostics;
const ui = core.ui;

const ConfiguredBinding = lua_config.ConfiguredBinding;
pub const InputRouter = host_inputs.Router;
pub const InputChunk = host_inputs.Chunk;

comptime {
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

const clipboard_images = @import("clipboard_images.zig");
const config_reload = @import("config_reload.zig");
const config_reloads = @import("config_reloads.zig");
const host_capabilities = @import("host_capabilities.zig");
const host_inputs = @import("host_inputs.zig");
const host_resizes = @import("host_resizes.zig");
const notification_timers = @import("notification_timers.zig");
const notification_flow = @import("notifications.zig");
const plugin_actions = @import("plugin_actions.zig");
const presenter_mod = @import("presenter.zig");
const server_messages = @import("server_messages.zig");
const sidebar_animations = @import("sidebar_animations.zig");

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
    plugin_result: plugin_actions.Completion,
    clipboard_image: clipboard_images.Completion,
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
telemetry: client_telemetry.State,
presenter: presenter_mod,
view: client_view.State,
model: client_model.Model,
navigation_history: navigation.History = .{},
graphics_store: kitty.Store,
host_input: host_inputs.State,
lua_generation: ?*lua_config.Generation,
plugin_registry: ?*plugin_broker.Registry,
trust_store: ?*core.plugin.TrustStore,
reload: config_reload.State,
sidebar_rendering: kitty.SidebarRendering,
sound_playback: sound_capability.Playback,
clipboard_capture_resources: attachments.CaptureResources = .{},

next_request_id: u64 = 2,
requests: client_requests.Tracker = .{},
sidebar_animation_scheduler: sidebar_animations.Scheduler = .{},
notification_scheduler: notification_timers.Scheduler = .{},

const Client = @This();

/// Creates a heap-owned client (the tab models alone are megabytes) and
/// takes ownership of the configuration generation, plugin registry and
/// trust store carried inside `params.options`; `deinit` releases them.
pub fn init(params: Params) !*Client {
    const gpa = params.gpa;
    const client = try gpa.create(Client);
    errdefer gpa.destroy(client);
    var capabilities: client_model.HostCapabilities = .{
        .window_width_px = params.window_width_px,
        .window_height_px = params.window_height_px,
    };
    var host_size = params.host_size;
    const cell_size = capabilities.cellSize(host_size.cols, host_size.rows);
    host_size.cell_width_px = cell_size.width;
    host_size.cell_height_px = cell_size.height;
    try host_size.validate();
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
    const configuration_generation = if (params.options.lua_generation) |generation|
        generation.number
    else
        0;
    var model = client_model.Model.initWithState(gpa, .{
        .pane_gaps = params.options.pane_gaps,
        .configuration_generation = configuration_generation,
        .host_size = host_size,
        .host_capabilities = capabilities,
    });
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
    const host_input = try host_inputs.State.init(params.input_file, .{
        .prefix = params.options.prefix,
        .bindings = params.options.bindings,
        .escape_timeout_ns = params.options.input_escape_timeout_ns,
        .sequence_timeout_ns = params.options.input_sequence_timeout_ns,
    });
    client.* = .{
        .io = params.io,
        .gpa = gpa,
        .connection = params.connection,
        .send_buffer = send_buffer,
        .receive_buffer = receive_buffer,
        .writer = params.writer,
        .select = undefined,
        .options = params.options,
        .telemetry = .init(params.io, params.options.endpoint),
        .presenter = undefined,
        .view = view,
        .model = model,
        .graphics_store = graphics_store,
        .host_input = host_input,
        .lua_generation = params.options.lua_generation,
        .plugin_registry = params.options.plugin_registry,
        .trust_store = params.options.trust_store,
        .sidebar_rendering = params.options.sidebar_rendering,
        .sound_playback = .init(params.options.sound),
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
        .metrics = &client.telemetry.metrics,
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
    client.telemetry.deinit(client.io);
    client.reload.deinit(gpa);
    client.clipboard_capture_resources.deinit(gpa);
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
    try client.presenter.observe(.{
        .model = client.model.version(),
        .graphics_ingress = client.graphics_store.ingressVersion(),
        .attachment_ingress = client.view.kittyAttachments().ingressVersion(),
    });
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

pub fn notify(client: *Client, input: notification_capability.Input) !void {
    _ = try notification_flow.publish(client, monotonic(client.io), input);
}

pub fn notifyDiagnostic(client: *Client, title: []const u8) !void {
    const message = client.model.diagnostic() orelse return error.ClientDiagnosticMissing;

    try client.notify(.{
        .level = .failure,
        .title = title,
        .message = message,
        .duration_ns = 7 * std.time.ns_per_s,
    });
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

/// Entrypoint for one completed local clipboard image capture.
///
/// ```zig
/// try client.handleClipboardImageEvent(completion);
/// ```
pub fn handleClipboardImageEvent(client: *Client, completion: clipboard_images.Completion) !void {
    try clipboard_images.complete(client, completion);
}

/// Entrypoint for one completed runtime socket read. It owns decode,
/// message dispatch, flow-control credit and receive rescheduling.
pub fn handleServerEvent(client: *Client, result: anyerror![]u8) !?u8 {
    const payload = try result;
    const decode_started = diagnostics.now(client.io);
    const message = try schema.decodeServer(payload);
    if (comptime diagnostics.enabled) {
        client.telemetry.metrics.server_messages += 1;
        client.telemetry.metrics.server_bytes += payload.len;
        switch (message) {
            .graphics_snapshot,
            .graphics_image,
            .graphics_shared_image,
            .graphics_image_chunk,
            .graphics_placement,
            .graphics_delete_image,
            .graphics_delete_placement,
            => {
                client.telemetry.metrics.graphics_messages += 1;
                client.telemetry.metrics.graphics_bytes += payload.len;
            },
            else => {},
        }
        client.telemetry.metrics.decode.observe(
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

/// Entrypoint for the capability-probe deadline: settle what the host never answered.
pub fn handleCapabilityTimeoutEvent(client: *Client, result: anyerror!void) !void {
    try result;
    _ = try host_capabilities.expire(client);
}

/// Entrypoint for a host terminal resize: remeasure, reflow, and re-offer sizes.
///
/// ```zig
/// try client.handleResizeEvent(result, source);
/// ```
pub fn handleResizeEvent(client: *Client, result: anyerror!void, source: host_resizes.Source) !void {
    _ = try host_resizes.handle(client, result, source);
}

/// Entrypoint for one completed socket send: pop it and pump the next.
pub fn handleSentEvent(client: *Client, result: anyerror!void) !void {
    try result;
    client.outbox.popSent();
    try client.returnGraphicsCredits();
    try host_inputs.scheduleRead(client);
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
    _ = try config_reloads.handle(client, result);
}

/// Entrypoint for one finished plugin action: authorize and apply its effects.
pub fn handlePluginResultEvent(client: *Client, completion: plugin_actions.Completion) !bool {
    return plugin_actions.complete(client, completion);
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

/// The model a due draw should present, or null while the client is not
/// presentable yet. Unwrapping the active tab here used to panic when a
/// resize arrived before the runtime answered the initial open request.
pub fn presentableModel(tabs: *tabs_mod.Model) ?*multiplexer.Model {
    const active = tabs.active() orelse return null;
    return &active.model;
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

pub fn waitCapabilityTimeout(io: Io) anyerror!void {
    const now = monotonic(io);
    const deadline = Io.Timestamp.fromNanoseconds(@intCast(now + kitty.capability_timeout_ns)).withClock(.awake);
    try deadline.wait(io);
}

pub fn monotonic(io: Io) u64 {
    const timestamp = Io.Timestamp.now(io, .awake);
    return @intCast(@max(timestamp.nanoseconds, 0));
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
