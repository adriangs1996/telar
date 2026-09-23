//! One attached client's shared state: the model, the runtime transport, the
//! request lifecycle, configuration, plugins and the ports through which a
//! presentation adapter supplies its host. Adapters embed it, build it in
//! place and bind the ports before the first event.
const lifecycle = @import("connection/lifecycle.zig");
const attachment_prompt = @import("operations/input/attachment_prompt.zig");
const markers_module = @import("attachments/markers.zig");
const sidebar_animation = @import("operations/notifications/sidebar_animation.zig");
const plugin_action = @import("operations/input/plugin_action.zig");
const data = @import("model");
const lua_diagnostics = @import("operations/configuration/lua_actions.zig");
const copy_mode_tests = @import("copy_mode_tests.zig");
const core = @import("telar-core");
const std = @import("std");
const config_reload = @import("resources/config_reload.zig");
const pane_graphics = @import("operations/panes/pane_graphics.zig");
const name_prompts = @import("operations/input/name_prompts.zig");
const layout_updates = @import("resources/client_layouts.zig");
const pane_mouse_input = @import("operations/input/pane_mouse_inputs.zig");
const agent_reading = @import("operations/agents/agent_reading.zig");
const builtin = @import("builtin");
const config_queries = @import("operations/configuration/config_queries.zig");
const bar_updates = @import("operations/configuration/bar_updates.zig");
const attached_client_tests = @import("attached_client_tests.zig");
const history_browser = @import("operations/input/history_browser.zig");
const pane_input_module = @import("operations/input/pane_input.zig");
const agent_snapshot_delivery = @import("operations/agents/agent_snapshot_delivery.zig");
const encoding_support = @import("input/encoding_support.zig");
const mouse_protocol_module = @import("input/mouse_protocol.zig");
const name_prompt_opening = @import("operations/input/name_prompt_opening.zig");
const path_queries = @import("operations/input/path_completions.zig");
const path_expansion = @import("completion/path_expansion.zig");
const client_diagnostic = @import("operations/configuration/client_diagnostic.zig");
const plugin_action_delivery = @import("operations/input/plugin_action_delivery.zig");
const clipboard_image = @import("operations/input/clipboard_image.zig");

const ctrl_h = data.chord.parseKey("ctrl+h") catch unreachable;
const ctrl_j = data.chord.parseKey("ctrl+j") catch unreachable;
const ctrl_k = data.chord.parseKey("ctrl+k") catch unreachable;
const ctrl_l = data.chord.parseKey("ctrl+l") catch unreachable;
const sidebar_animation_interval_ns = 120 * std.time.ns_per_ms;

const Options = @import("Options.zig");
const ClientInit = @import("ClientInit.zig");
const RuntimeTransportState = @import("connection/RuntimeTransportState.zig");
const TelemetryState = @import("resources/TelemetryState.zig");
const Generation = @import("config/Generation.zig");
const Snapshot = @import("config/Snapshot.zig");
const Registry = @import("plugins/Registry.zig");
const ConfigReloadState = @import("resources/ConfigReloadState.zig");
const GraphicsRetention = @import("graphics/GraphicsRetention.zig");
const HostChrome = @import("presentation/HostChrome.zig");
const AttachmentCatalogPort = @import("attachments/AttachmentCatalogPort.zig");
const AttachmentShelf = @import("attachments/AttachmentShelf.zig");
const PresentationLifecycle = @import("presentation/LifecycleState.zig");
const Workers = @import("execution/Workers.zig");
const Message = @import("execution/Message.zig").Message;
const HostInputSource = @import("input/HostInputSource.zig");
const Adoption = @import("resources/Adoption.zig");
const RouterConfig = @import("input/RouterConfig.zig");
const ConfiguredPlugins = @import("plugins/ConfiguredPlugins.zig");

/// Bindings obey prompt authority; validated native effects retain their caller's authority.
const ActionOrigin = enum { binding, effect };
const SplitRecovery = enum { restored, not_required, stale };
const PaneOpenOutcome = enum { workspace_arrived, workspace_created, pane_split, pane_attached, ignored };
const TabSnapshotOutcome = enum { applied, ignored };
const TabSnapshotRecovery = enum { coalesced, requested };
const TabCloseOutcome = enum { applied, ignored, exit };
const WorkspaceSwitchTarget = union(enum) { workspace: core.WorkspaceId, pane: data.PaneRequest };
const WorkspaceSwitchAuthority = enum { requested_departure, canonical_follow };
const WorkspaceRecovery = enum { retried, unrecoverable };
const AgentSoundOutcome = enum { stale, accepted };
const ResyncOutcome = enum { coalesced, snapshot_requested, handoff_requested, exit };
const FocusReportOutcome = enum { applied, unchanged };
const AgentNavigationOutcome = enum { ignored, focused, handoff_requested };

comptime {
    std.debug.assert(data.effects.max_expression_paste_bytes + 16 <= data.input_limits.max_encoded_bytes);
}

const AttachedClient = @This();

io: std.Io,
gpa: std.mem.Allocator,
runtime_transport: RuntimeTransportState,
options: Options,
client_identity: core.ClientIdentity,
telemetry: TelemetryState,
model: data.ClientModel,
lua_generation: ?*Generation,
plugin_registry: ?*Registry,
trust_store: ?*core.TrustStore,
reload: ConfigReloadState,
/// Transient: the alternate flag of the list submission being finished.
list_submission_alternate: bool = false,
/// Host ports, bound by the adapter before the first event.
/// Runs client jobs on the adapter's event loop.
workers: Workers = undefined,
graphics: GraphicsRetention = undefined,
chrome: HostChrome = undefined,
attachment_catalog: AttachmentCatalogPort = undefined,
attachment_shelf: AttachmentShelf = undefined,
/// The one presentation in flight and what the host last delivered, shared
/// by every adapter.
presentation: PresentationLifecycle = .{},
host_input_source: HostInputSource = undefined,

/// Builds the shared state in its final address. The model is megabytes, so
/// nothing here passes it by value. Ports remain unbound.
///
/// ```zig
/// try AttachedClient.init(&terminal.app, .{ .gpa = gpa, .io = io, .connection = connection, .host_size = size, .options = options });
/// ```
pub fn init(client: *AttachedClient, params: ClientInit) !void {
    const gpa = params.gpa;
    var capabilities: data.HostCapabilities = .{
        .window_width_px = params.window_width_px,
        .window_height_px = params.window_height_px,
    };

    var host_size = params.host_size;
    const cell_size = capabilities.cellSize(host_size.cols, host_size.rows);
    host_size.cell_width_px = cell_size.width;
    host_size.cell_height_px = cell_size.height;
    try host_size.validate();
    const configuration_generation = if (params.options.lua_generation) |generation|
        generation.number
    else
        0;
    const snapshot: ?*const Snapshot = if (params.options.lua_generation) |generation| &generation.snapshot else null;
    // The client owns these from here on; `options` keeps no second pointer
    // that a reload could leave dangling.
    var options = params.options;
    options.lua_generation = null;
    options.plugin_registry = null;
    options.trust_store = null;
    var runtime_transport_state = try RuntimeTransportState.init(gpa, params.connection);
    errdefer runtime_transport_state.deinit(gpa);

    client.* = .{
        .io = params.io,
        .gpa = gpa,
        .runtime_transport = runtime_transport_state,
        .options = options,
        .client_identity = params.client_identity,
        .telemetry = .init(params.io, params.options.endpoint),
        .model = undefined,
        .lua_generation = params.options.lua_generation,
        .plugin_registry = params.options.plugin_registry,
        .trust_store = params.options.trust_store,
        .reload = .{ .mtime_ns = params.options.config_mtime_ns },
    };

    client.model.initInto(gpa, .{
        .pane_gaps = params.options.pane_gaps,
        .configuration_generation = configuration_generation,
        .bars = params.options.bars,
        .host_size = host_size,
        .host_capabilities = capabilities,
        .sidebar_width = data.sidebar.default_width,
        .config = config: {
            var config: data.Config = if (snapshot) |value| configFrom(value) else .{};
            config.sidebar_rendering = params.options.sidebar_rendering;
            break :config config;
        },
        .theme = params.options.theme,
        .icon_theme = params.options.icon_theme,
        .window_title = if (snapshot) |value| value.windowTitle() else "",
    });
    errdefer client.model.deinit();
    client.model.sound_playback = .init(params.options.sound);
    try client.model.history_palette.prepare(gpa);
    _ = client.model.setSidebarVisible(params.options.sidebar_visible);
}

/// The key bindings of the live configuration, borrowed from its
/// generation until the next adoption.
/// Example: `const router = try buildRouter(client.routerConfig());`
pub fn routerConfig(client: *const AttachedClient) RouterConfig {
    if (client.lua_generation) |generation| {
        const snapshot = &generation.snapshot;
        return .{
            .prefix = snapshot.prefix,
            .bindings = snapshot.bindingSlice(),
            .escape_timeout_ns = snapshot.input_escape_timeout_ns,
            .sequence_timeout_ns = snapshot.input_sequence_timeout_ns,
        };
    }

    return .{
        .prefix = client.options.prefix,
        .bindings = client.options.bindings,
        .escape_timeout_ns = client.options.input_escape_timeout_ns,
        .sequence_timeout_ns = client.options.input_sequence_timeout_ns,
    };
}

/// Returns the grid the active tab's panes share.
/// Example: `const region = client.geometry();`.
pub fn geometry(client: *const AttachedClient) data.Region {
    return data.workbench.region(&client.model);
}

/// Releases shared state. The adapter cancels its tasks and frees its own
/// resources first; nothing here may still be borrowed by a worker.
///
/// ```zig
/// terminal.app.deinit();
/// ```
pub fn deinit(client: *AttachedClient) void {
    const gpa = client.gpa;
    client.telemetry.deinit(client.io);
    client.reload.deinit(gpa);
    if (client.lua_generation) |generation| {
        generation.deinit();
    }

    if (client.plugin_registry) |registry| {
        gpa.destroy(registry);
    }

    if (client.trust_store) |store| {
        gpa.destroy(store);
    }

    client.model.deinit();
    client.runtime_transport.deinit(gpa);
}

/// Uses the current generation so editor changes take effect after reload.
/// Example: `const executable = client.editorExecutable();`
pub fn editorExecutable(self: *const AttachedClient) []const u8 {
    if (self.lua_generation) |generation| {
        return generation.snapshot.resolveEditor(self.options.editor);
    }

    return self.options.editor;
}

/// Copies one fixed-size message and starts its write when idle.
/// Example: `try self.sendRuntime(.{ .detach_pane = detach });`
pub fn sendRuntime(self: *AttachedClient, message: data.outbox_support.Message) !void {
    try self.runtime_transport.outbox.push(message);
    try self.startRuntimeSend();
}

/// Copies bounded pane input and starts its write when idle.
///
/// ```zig
/// try self.sendRuntimeInput(.{ .pane_id = pane_id, .bytes = bytes });
/// ```
pub fn sendRuntimeInput(self: *AttachedClient, input: core.PaneInput) !void {
    if (input.bytes.len > data.input_limits.max_encoded_bytes) {
        try self.runtime_transport.outbox.pushInputBatch(input.pane_id, input.bytes);
    } else {
        try self.runtime_transport.outbox.pushInput(input.pane_id, input.bytes);
    }

    try self.startRuntimeSend();
}

/// Starts the receive loop before sending the queued bootstrap.
/// Example: `try client.startRuntimeIo();`
pub fn startRuntimeIo(self: *AttachedClient) !void {
    try self.startRuntimeRead();
    try self.startRuntimeSend();
}

/// Handles one client event an adapter delivered and returns an exit
/// status when the client must stop.
///
/// ```zig
/// if (try app.update(message)) |status| return status;
/// ```
pub fn update(self: *AttachedClient, message: Message) !?u8 {
    const path = core.enter(message.path());
    defer path.restore();

    switch (message) {
        .server => |result| return self.receiveRuntime(result),
        .sent => |result| try self.completeRuntimeSend(result),
        .sidebar_animation_tick => |result| _ = try self.completeSidebarAnimationTick(result),
        .notification_tick => |result| _ = try self.completeNotificationTick(result),
        .bar_tick => |result| try bar_updates.handleTick(self, result),
        .bar_command => |completion| try bar_updates.completeCommand(self, completion),
        .plugin_result => |completion| {
            if (try self.completePluginAction(completion)) {
                return 0;
            }
        },
        .path_completion => |completion| try self.completePathCompletion(completion),
        .link_opened => |result| try self.completeLinkOpening(result),
        .sound_played => |result| try self.completeAgentSound(result),
        .notified => |result| result catch {},
        .config_reload => |result| _ = try self.completeConfigReload(result),
    }

    return null;
}

/// Reserves a receive buffer and releases it if the driver rejects the read.
/// Example: `try client.startRuntimeRead();`
pub fn startRuntimeRead(self: *AttachedClient) !void {
    const transport = &self.runtime_transport;
    if (!transport.beginRead()) {
        return;
    }

    self.workers.start(.{ .runtime_read = transport }) catch |err| {
        transport.cancelRead();

        return err;
    };
}

/// Releases one runtime read, dispatches its bounded message and rearms only
/// while the client remains alive.
///
/// ```zig
/// if (try self.receiveRuntime(result)) |status| return status;
/// ```
pub fn receiveRuntime(self: *AttachedClient, result: anyerror!*const data.RuntimeMessage) !?u8 {
    core.profiling.add(.client_receive, 1);
    core.mark(self.io, .client_frame);
    const received = try self.runtime_transport.completeRead(result);
    self.telemetry.recordMessage(received);
    const status = try self.handleServerMessage(received.message);

    if (status) |exit_status| {
        return exit_status;
    }

    self.queueGraphicsCredits();
    try self.startRuntimeSend();
    try self.startRuntimeRead();

    return null;
}

/// Applies one decoded reply while its borrowed payload remains valid.
/// Example: `_ = try self.handleServerMessage(message);`
pub fn handleServerMessage(self: *AttachedClient, message: core.ServerMessage) !?u8 {
    switch (message) {
        .change_review_changed => |notification| {
            _ = self.changeReviewChanged(notification);
        },
        .change_review_snapshot => |snapshot| {
            _ = try self.applyChangeReview(snapshot);
        },
        .editor_opened => |reply| {
            try self.completeEditorOpen(reply);
        },
        .agent_history_page => |page| {
            _ = try self.applyAgentHistory(page);
        },
        .agent_thread_snapshot => |snapshot| {
            _ = try self.model.applyAgentThread(snapshot);
        },
        .request_completed => |reply| {
            try self.completeAgentRequest(reply);
        },
        .pane_opened => |opened| _ = try self.completePaneOpen(opened),
        .tab_snapshot => |snapshot| _ = try self.applyTabSnapshot(snapshot),
        .workspace_snapshot => |snapshot| try self.applyWorkspaceSnapshot(snapshot),
        .tab_created => |created| _ = try self.completeTabCreation(created),
        .tab_renamed => |renamed| _ = try self.completeTabRename(renamed),
        .tab_closed => |closed| switch (try self.completeTabClose(closed)) {
            .applied, .ignored => {},
            .exit => return 0,
        },
        .tab_moved => |moved| _ = try self.completeTabMove(moved),
        .pane_frame => |frame| _ = try self.applyPaneFrame(frame),
        .pane_cwd => |cwd| _ = try self.model.updatePaneMetadata(
            .{
                .cwd = .{
                    .pane_id = cwd.pane_id,
                    .path = cwd.cwd,
                },
            },
        ),
        .pane_foreground => |foreground| _ = try self.model.updatePaneMetadata(
            .{
                .foreground = .{
                    .pane_id = foreground.pane_id,
                    .name = foreground.name,
                },
            },
        ),
        .pane_title => |title| _ = try self.model.updatePaneMetadata(
            .{
                .title = .{
                    .pane_id = title.pane_id,
                    .title = title.title,
                },
            },
        ),
        .pane_progress => |progress| _ = try self.applyPaneProgress(progress),
        .client_command => |command| try self.completeClientCommand(command),
        .pane_focus_command => |command| try self.completePaneFocusCommand(command),
        .pane_matches => |found| _ = try self.applyPaneMatches(found),
        .pane_clipboard => |clipboard| {
            if (clipboard.pane_id == .invalid) {
                return error.UnexpectedPane;
            }
            try self.model.to_host.writeClipboard(self.gpa, clipboard.bytes);
        },
        .pane_exited => |exited| _ = try self.applyPaneExit(exited),
        .request_failed => |failure| {
            if (!self.model.history_palette.fail(failure)) {
                _ = try self.failRuntimeRequest(failure);
            }
        },
        .notification => |notification| _ = try self.applyRuntimeNotification(notification),
        .notification_shown => |shown| _ = try self.completeNotificationDelivery(shown),
        .agent_sound => |sound| _ = try self.applyAgentSound(sound),
        .client_layout_snapshot => |snapshot| try self.restoreClientLayout(snapshot),
        .resync_required => |required| {
            if (try self.applyResyncRequirement(required) == .exit) {
                return 0;
            }
        },
        .runtime_stopping => return 0,
        .history_results => |results| _ = try self.applyHistoryResults(results),
        .history_pruned => |confirmation| _ = try self.completeHistoryPrune(confirmation),
        .history_output => |output| _ = self.model.history_palette.applyOutput(output),
        .command_suggestion => |suggested| _ = self.model.suggestion.apply(suggested),
        .client_command_result, .client_list, .pane_text, .history_stats_result, .pane_focus_result => return error.UnexpectedControlReply,
        .proxy_status => |status| _ = try self.applyProxyStatus(status),
        .agent_snapshot => |snapshot| _ = try self.applyAgentSnapshot(snapshot),
        .system_metrics => |metrics| _ = try self.model.reconcileSystemMetrics(
            .{
                .runtime_revision = metrics.revision,
                .cpu_percent = metrics.cpu_percent,
                .memory_used_decigib = metrics.memory_used_decigib,
                .battery_percent = if (metrics.has_battery) metrics.battery_percent else null,
            },
        ),
        .workspace_list => |list| _ = try self.model.applyWorkspaceList(list),
        .graphics_snapshot => |snapshot| _ = try self.applyPaneGraphics(
            .{
                .snapshot = snapshot,
            },
        ),
        .graphics_image => |image| _ = try self.applyPaneGraphics(
            .{
                .image = image,
            },
        ),
        .graphics_shared_image => |image| _ = try self.applyPaneGraphics(
            .{
                .shared_image = image,
            },
        ),
        .graphics_image_chunk => |chunk| _ = try self.applyPaneGraphics(
            .{
                .image_chunk = chunk,
            },
        ),
        .graphics_placement => |placement| _ = try self.applyPaneGraphics(
            .{
                .placement = placement,
            },
        ),
        .graphics_delete_image => |deleted| _ = try self.applyPaneGraphics(
            .{
                .delete_image = deleted,
            },
        ),
        .graphics_delete_placement => |deleted| _ = try self.applyPaneGraphics(
            .{
                .delete_placement = deleted,
            },
        ),
    }

    return null;
}

/// Executes a binding or a validated native effect with its existing prompt policy.
/// Example: `_ = try self.executeAction(.{ .split_pane = .horizontal }, .binding);`
pub fn executeAction(self: *AttachedClient, value: data.Action, origin: ActionOrigin) anyerror!data.KeybindControl {
    if (origin == .binding and self.model.name_prompt.active()) {
        return .continue_routing;
    }

    switch (value) {
        .lua_callback, .lua_expr => {
            std.debug.assert(origin == .binding);
            return self.executeLuaAction(switch (value) {
                .lua_callback => |reference| .{
                    .callback = reference,
                },
                .lua_expr => |reference| .{
                    .expression = reference,
                },
                else => unreachable,
            });
        },
        .plugin => |requested| {
            std.debug.assert(origin == .binding);
            _ = try self.startPluginAction(requested, self.model.callbackContext());
            return .continue_routing;
        },
        else => {},
    }

    if (value != .enter_copy_mode and self.copyModeActive()) {
        _ = try self.leaveCopyMode();
    }

    switch (value) {
        .toggle_thread_view => {
            _ = self.model.togglePaneSurface();
        },
        .scroll_pane => |direction| try self.scrollPane(direction),
        .split_pane => |direction| _ = try self.requestPaneSplit(
            .{
                .axis = switch (direction) {
                    .horizontal => .horizontal,
                    .vertical => .vertical,
                },
                .area = self.geometry().area,
            },
        ),
        .focus_pane => |direction| _ = try self.applyPaneFocus(
            .{
                .target = .{
                    .direction = switch (direction) {
                        .left => .left,
                        .right => .right,
                        .up => .up,
                        .down => .down,
                    },
                },
                .area = self.geometry().area,
            },
        ),
        .navigate_pane => |direction| try self.navigatePane(direction),
        .resize_pane => |direction| _ = try self.resizePane(
            .{
                .direction = switch (direction) {
                    .left => .left,
                    .right => .right,
                    .up => .up,
                    .down => .down,
                },
                .area = self.geometry().area,
            },
        ),
        .toggle_pane_fullscreen => _ = try self.togglePaneFullscreen(
            .{
                .area = self.geometry().area,
            },
        ),
        .toggle_sidebar => _ = try self.toggleSidebar(),
        .resize_sidebar => |direction| _ = try self.resizeSidebar(
            .{
                .direction = switch (direction) {
                    .left => .narrower,
                    .right => .wider,
                },
            },
        ),
        .toggle_workspace_list => _ = self.model.toggleWorkspaceList(),
        .new_workspace => _ = self.beginWorkspacePrompt(),
        .rename_workspace => _ = self.openNamePrompt(.rename_workspace),
        .select_workspace => |position| _ = try self.selectWorkspace(
            .{
                .position = position,
            },
        ),
        .close_pane => _ = try self.requestPaneClose(),
        .new_tab => _ = try self.requestTabCreation(
            .{},
        ),
        .new_agent_tab => try self.createAgentTab(),
        .select_tab_offset => |offset| _ = try self.selectTab(
            .{
                .target = .{
                    .offset = offset,
                },
            },
        ),
        .select_tab => |position| _ = try self.selectTab(
            .{
                .target = .{
                    .position = position,
                },
            },
        ),
        .rename_tab => _ = self.openNamePrompt(.rename_active_tab),
        .close_tab => _ = try self.requestTabClose(),
        .move_tab => |direction| _ = try self.requestTabMove(
            .{
                .direction = switch (direction) {
                    .previous => .previous,
                    .next => .next,
                },
            },
        ),
        .detach => {
            try self.synchronizeClientLayout();
            try self.detachAllTabs();

            return .stop;
        },
        .enter_copy_mode => _ = self.enterCopyMode(),
        .command_tab => |*command| try self.createCommandTab(command),
        .goto_picker => _ = self.openNamePrompt(.goto_picker),
        .history_palette => _ = try self.beginHistoryPalette(),
        .suggest_command => _ = try self.beginSuggestion(),
        .notification => |*notification| _ = try self.requestNotificationDelivery(notification),
        .lua_callback, .lua_expr, .plugin => unreachable,
    }

    return .continue_routing;
}

/// Registers correlation before copying the request; failed delivery removes only that registration.
/// Example: `try self.sendRuntimeRequest(delivery);`
pub fn sendRuntimeRequest(self: *AttachedClient, delivery: data.ConnectionDelivery) !void {
    try self.model.request_lifecycle.tracker.add(delivery.registration.request_id, delivery.registration.continuation);
    errdefer _ = self.model.request_lifecycle.tracker.take(delivery.registration.request_id);
    try self.runtime_transport.outbox.push(delivery.message);
    try self.startRuntimeSend();
}

/// Registers correlation before copying the request; failed delivery removes only that registration.
/// Example: `try self.sendWorkspaceRenameRequest(rename);`
pub fn sendWorkspaceRenameRequest(self: *AttachedClient, rename: core.RenameWorkspace) !void {
    try self.model.request_lifecycle.tracker.add(
        rename.request_id,
        .{
            .rename_workspace = rename.workspace,
        },
    );
    errdefer _ = self.model.request_lifecycle.tracker.take(rename.request_id);
    try self.runtime_transport.outbox.pushWorkspaceRename(rename);
    try self.startRuntimeSend();
}

/// Synchronizes the focused attachment before reporting child focus. Example: `try self.synchronizeActivePane();`
pub fn synchronizeActivePane(self: *AttachedClient) !void {
    _ = try self.synchronizePaneAttachments();
    _ = try self.synchronizeReportedFocus();
}

/// Acknowledges a completed agent and reconciles its focused attachment shelf. Example: `_ = try self.synchronizePaneAttachments();`
pub fn synchronizePaneAttachments(self: *AttachedClient) !bool {
    if (self.model.takeAgentAcknowledgement()) |key| {
        try self.sendRuntime(
            .{
                .acknowledge_agent = .{
                    .pane_id = key.pane_id,
                    .pane_generation = key.pane_generation,
                },
            },
        );
    }

    if (!self.attachment_shelf.syncTarget(self.model.focusedAttachmentTarget())) {
        return false;
    }

    if (self.model.tabs.activeSlot()) |tab| {
        try self.resizeAttachedPanes(tab, self.geometry().area);
    }

    return true;
}

/// Commits one split-edge move before delivering geometry. Example: `_ = try self.resizePane(command);`
pub fn resizePane(self: *AttachedClient, command: data.ResizePaneRequest) !?data.PaneGeometryChange {
    const change = self.model.resizePane(command) orelse return null;
    try self.deliverPaneGeometry(change);

    return change;
}

/// Commits fullscreen state before delivering geometry. Example: `_ = try self.togglePaneFullscreen(command);`
pub fn togglePaneFullscreen(self: *AttachedClient, command: data.TogglePaneFullscreenRequest) !?data.PaneGeometryChange {
    const change = self.model.togglePaneFullscreen(command) orelse return null;
    try self.deliverPaneGeometry(change);

    return change;
}

/// Requests creation without committing layout; restores geometry if delivery fails.
/// Example: `_ = try self.requestPaneSplit(.{ .axis = .horizontal, .area = self.geometry().area });`
pub fn requestPaneSplit(self: *AttachedClient, command: data.RequestPaneSplit) !?data.PaneSplitPlan {
    if (self.model.request_lifecycle.tracker.has(.pane_operation)) {
        return null;
    }

    const plan = self.model.planPaneSplit(command) orelse return null;
    self.sendRuntime(
        .{
            .pane_resize = plan.provisional_resize,
        },
    ) catch |err| {
        try self.sendRuntime(
            .{
                .pane_resize = plan.restore_resize,
            },
        );
        return err;
    };

    self.sendPaneSplitRequest(plan) catch |err| {
        try self.sendRuntime(
            .{
                .pane_resize = plan.restore_resize,
            },
        );
        return err;
    };

    return plan;
}

/// Releases one runtime write, pumps its successor and resumes host input when
/// one queue slot becomes available.
///
/// ```zig
/// try self.completeRuntimeSend(result);
/// ```
pub fn completeRuntimeSend(self: *AttachedClient, result: anyerror!void) !void {
    try self.runtime_transport.outbox.finishSend(result);
    self.queueGraphicsCredits();
    try self.startRuntimeSend();
    self.model.to_host.resume_input = true;
}

/// Returns available graphics credits and starts their delivery.
/// Example: `try client.flushGraphicsCredits();`
pub fn flushGraphicsCredits(self: *AttachedClient) !void {
    self.queueGraphicsCredits();
    try self.startRuntimeSend();
}

/// Commits validated geometry before touching resources. Delivery failure keeps
/// the committed state; the caller ends the client session.
/// Example: `_ = try self.applyHostUpdate(host_update);`
pub fn applyHostUpdate(self: *AttachedClient, host_update: data.HostUpdate) !?data.HostCommit {
    const commit = try self.model.reconcileHost(host_update) orelse return null;

    try self.deliverHostCommit(commit);

    return commit;
}

/// Applies a semantic terminal response through the same resource policy.
/// Example: `_ = try self.observeHostCapability(observation);`
pub fn observeHostCapability(self: *AttachedClient, observation: data.HostCapabilityObservation) !?data.HostCommit {
    const commit = try self.model.observeHostCapability(observation) orelse return null;

    try self.deliverHostCommit(commit);

    return commit;
}

/// Resolves geometry when a probe settles a complete set of capabilities.
/// Example: `_ = try self.reconcileHostCapabilities(capabilities);`
pub fn reconcileHostCapabilities(self: *AttachedClient, capabilities: data.HostCapabilities) !?data.HostCommit {
    var size = self.model.host.host_size;
    const cell_size = capabilities.cellSize(size.cols, size.rows);
    size.cell_width_px = cell_size.width;
    size.cell_height_px = cell_size.height;

    return self.applyHostUpdate(
        .{
            .size = size,
            .capabilities = capabilities,
        },
    );
}

/// Offers sizes for attached visible panes, reserving space for the attachment shelf.
/// Example: `try self.resizeAttachedPanes(tab, area);`
pub fn resizeAttachedPanes(self: *AttachedClient, tab: usize, area: core.Rect) !void {
    var layout = data.tab_layout.snapshot(&self.model, tab, area).*;
    _ = layout.reserveBelowPane(self.attachment_shelf.reservation());
    var panes = self.model.panes.iterate(self.model.tabs.location[tab].tab_id);

    while (panes.next()) |pane| {
        if (!pane.attached) {
            continue;
        }

        const view = layout.find(pane.id) orelse continue;
        var size = data.multiplexer.rectSize(view.content) orelse continue;
        size.cell_width_px = self.model.host.host_size.cell_width_px;
        size.cell_height_px = self.model.host.host_size.cell_height_px;
        try self.sendRuntime(
            .{
                .pane_resize = .{
                    .pane_id = pane.id,
                    .size = size,
                },
            },
        );
    }
}

/// Selects the live configuration resources before scheduling their next watch.
/// No configured file means no watch; incomplete ownership is an explicit error.
/// Example: `try client.scheduleConfigReload();`
pub fn scheduleConfigReload(self: *AttachedClient) !void {
    const path = self.options.config_path orelse return;
    const trust_path = self.options.trust_path orelse return error.ConfigurationNotLoaded;
    const generation = self.lua_generation orelse return error.ConfigurationNotLoaded;
    const registry = self.plugin_registry orelse return error.ConfigurationNotLoaded;

    try config_reload.schedule(
        &self.reload,
        .{
            .io = self.io,
            .gpa = self.gpa,
            .workers = self.workers,
            .path = path,
            .profile = self.options.profile,
            .trust_path = trust_path,
            .current_generation = generation,
            .current_registry = registry,
        },
    );
}

/// Borrows bar sources only when Lua and the model agree on their generation.
/// Example: `const configuration = client.barConfiguration() orelse return;`
pub fn barConfiguration(self: *const AttachedClient) ?*const data.BarConfiguration {
    const generation = self.lua_generation orelse return null;

    if (generation.number != self.model.configuration_generation) {
        return null;
    }

    return &generation.snapshot.bars;
}

/// Replaces bar deadlines from the active configuration and rearms their timer.
/// Example: `try client.synchronizeBars();`
pub fn synchronizeBars(self: *AttachedClient) !void {
    self.model.bar_updates.synchronize(
        .{
            .generation = if (self.lua_generation) |generation| generation.number else self.model.configuration_generation,
            .configuration = self.barConfiguration(),
            .now_ns = core.monotonic(self.io),
        },
    );

    try bar_updates.rearm(self.workers, self.io, &self.model.bar_updates);
}

/// Snapshot the current exclusive keyboard owners without exposing client state.
/// Example: `const captures_keys = key_policy.captures(self.keyRoutingAuthority());`
pub fn keyRoutingAuthority(self: *const AttachedClient) data.KeyRoutingAuthority {
    return .{
        .attachment_modal_active = self.attachment_shelf.modalActive(),
        .prompt_active = self.model.name_prompt.active(),
        .copy_mode_active = self.model.copyModeActive(),
    };
}

/// An exclusive owner or unavailable pane prevents held-action repetition.
/// Re-read after executing an action because it may change focus or modes.
/// Example: `const policy = repeatPolicy(action, self.repeatPane());`
pub fn repeatPane(self: *const AttachedClient) ?core.PaneId {
    const authority = self.keyRoutingAuthority();
    if (data.key_routing.captures(authority) or authority.copy_mode_active) {
        return null;
    }

    const model = self.model.tabs.activeSlot() orelse return null;
    const pane = data.tab_layout.focusedPaneConst(&self.model, model) orelse return null;
    return if (pane.attached) pane.id else null;
}

/// Opens the latest review for any attached pane, preserving an already open edition.
/// Example: `try app.openChangeReview(pane_id);`
pub fn openChangeReview(self: *AttachedClient, pane_id: core.PaneId) !void {
    try self.openChangeReviewSession(pane_id);
    try self.queryChangeReview(if (self.model.change_review.loaded) self.model.change_review.snapshot.edition_id else 0);
}

/// Zero requests latest; explicit navigation never replaces a review on new edits.
/// Example: `try app.queryChangeReview(edition_id);`
pub fn queryChangeReview(self: *AttachedClient, edition_id: u64) !void {
    const owner = self.changeReviewOperation(edition_id) catch |err| {
        self.reportChangeReview(@errorName(err));
        return err;
    };

    const request_id = try self.model.request_lifecycle.nextId();
    try self.model.request_lifecycle.tracker.add(
        request_id,
        .{
            .change_review_query = owner,
        },
    );
    self.beginChangeReview(request_id);
    self.sendRuntimeChangeReviewQuery(
        .{
            .request_id = request_id,
            .pane_id = owner.pane_id,
            .pane_generation = owner.pane_generation,
            .edition_id = edition_id,
            .session = owner.sessionSlice(),
        },
    ) catch |err| {
        _ = self.model.request_lifecycle.tracker.take(request_id);
        _ = self.failChangeReview(owner, @errorName(err));
        return err;
    };
}

/// Sends one mutation while retaining both the canonical snapshot and local draft.
/// Pass the displayed edition and revision to bind a delayed gesture to its owner.
/// Example: `try app.commandChangeReview(request);`
pub fn commandChangeReview(self: *AttachedClient, request: core.ChangeReviewCommand) !void {
    if (!self.model.change_review.loaded) {
        self.reportChangeReview("No change review is loaded");
        return error.ChangeReviewNotLoaded;
    }

    const edition_id = if (request.edition_id == 0) self.model.change_review.snapshot.edition_id else request.edition_id;
    const owner = self.changeReviewOperation(edition_id) catch |err| {
        self.reportChangeReview(@errorName(err));
        return err;
    };

    var outgoing = request;
    outgoing.request_id = try self.model.request_lifecycle.nextId();
    outgoing.pane_id = owner.pane_id;
    outgoing.pane_generation = owner.pane_generation;
    outgoing.edition_id = edition_id;
    outgoing.session = owner.sessionSlice();
    if (outgoing.expected_revision == 0) {
        outgoing.expected_revision = self.model.change_review.snapshot.revision;
    }

    try self.model.request_lifecycle.tracker.add(
        outgoing.request_id,
        .{
            .change_review_command = owner,
        },
    );
    self.beginChangeReview(outgoing.request_id);
    self.sendRuntimeChangeReviewCommand(outgoing) catch |err| {
        _ = self.model.request_lifecycle.tracker.take(outgoing.request_id);
        _ = self.failChangeReview(owner, @errorName(err));
        return err;
    };
}

/// Drains notices after the view consumes mutation success or failure, so a later
/// refresh can never be mistaken for the acknowledgement of an earlier save.
/// Example: `app.refreshChangeReview();`
pub fn refreshChangeReview(self: *AttachedClient) void {
    if (self.model.change_review.needsRefresh() and self.model.change_review.errorSlice().len == 0) {
        self.queryChangeReview(if (self.model.change_review.loaded) self.model.change_review.snapshot.edition_id else 0) catch {};
    }
}

/// Resolves the review owner without retaining an address across lifecycle changes.
/// Example: `_ = app.isChangeReviewAttached();`
pub fn isChangeReviewAttached(self: *AttachedClient) bool {
    const owner = self.model.change_review.owner orelse return false;
    return resolveReviewPane(&self.model, owner) != null;
}

/// Example: `app.closeChangeReview();`
pub fn closeChangeReview(self: *AttachedClient) void {
    self.model.change_review.close();
    self.model.chrome_revision +%= 1;
}

/// Dispatches one owned target without letting opener failures leave input.
/// Example: `_ = try app.openLink(target);`
pub fn openLink(self: *AttachedClient, target: data.LinkTarget) !bool {
    const result = switch (target.scheme) {
        .file => open: {
            const path = data.FilePath.init(&target) catch |err| {
                try self.reportLinkFailure(err);
                return false;
            };

            break :open self.openLinkFile(path);
        },
        .http, .https, .external => self.openExternalLink(target),
    };

    result catch |err| {
        try self.reportLinkFailure(err);
        return false;
    };

    return true;
}

/// Gives a textual link first refusal before child mouse reporting.
/// Example: `_ = try app.inputLinkPointer(tab, event);`
pub fn inputLinkPointer(self: *AttachedClient, tab: usize, event: data.Mouse) !bool {
    const command: data.LinksPointerCommand = .{
        .kind = switch (event.kind) {
            .press => .press,
            .release => .release,
            .drag => .drag,
            else => .other,
        },
        .left_button = event.button & 0b11 == 0,
        .right_button = event.button & 0b11 == 2,
    };

    const target = if (command.kind == .press and (command.left_button or command.right_button) and event.button & 4 == 0)
        linkTargetAt(
            &self.model,
            tab,
            event,
            self.geometry().area,
        )
    else
        null;
    const outcome = self.model.link_pointer.handle(command, target);
    if (outcome.open) |selected| {
        _ = try self.openLink(selected);
    }

    if (outcome.copy) |selected| {
        try self.model.to_host.writeClipboard(self.gpa, selected.uri());
    }

    return outcome.consumed;
}

/// Completes one host worker and starts the last target queued behind it.
/// Example: `try app.completeLinkOpening(result);`
pub fn completeLinkOpening(self: *AttachedClient, result: anyerror!void) !void {
    if (result) |_| {} else |err| {
        try self.reportLinkFailure(err);
    }

    const next = self.model.link_opening.complete() orelse return;
    self.workers.start(.{ .link = next }) catch |err| {
        self.model.link_opening.schedulingFailed();
        try self.reportLinkFailure(err);
    };
}

/// Reuses a reachable editor in the source tab, otherwise creates a sibling pane.
/// Example: `_ = try app.openMessageFile(pane_id, path);`
pub fn openMessageFile(self: *AttachedClient, pane_id: core.PaneId, path: data.FilePath) !bool {
    self.openEditorPane(pane_id, path) catch |err| {
        try self.reportLinkFailure(err);
        return false;
    };

    return true;
}

/// Starts at most one history request for this connection after frame delivery.
/// Example: `try app.flushAgentHistory();`
pub fn flushAgentHistory(self: *AttachedClient) !void {
    if (self.model.request_lifecycle.tracker.has(.agent_history)) {
        return;
    }

    const tab = self.model.tabs.activeSlot() orelse return;
    var panes = self.model.panes.iterate(self.model.tabs.location[tab].tab_id);
    while (panes.next()) |pane| {
        if (pane.history_intent == null) {
            continue;
        }

        var query = (agent_reading.begin(&self.model, pane.id) catch |err| {
            try self.reportAgentHistoryFailure(@errorName(err));
            continue;
        }) orelse continue;
        const operation: data.AgentHistoryOperation = .{
            .owner = .{
                .pane_id = pane.id,
                .pane_generation = pane.pane_generation,
                .attachment_generation = pane.attachment_generation,
                .location = pane.location,
            },
            .view_generation = query.view_generation,
        };

        query.request_id = self.model.request_lifecycle.nextId() catch |err| {
            _ = agent_reading.failed(
                &self.model,
                operation,
                @errorName(err),
            );
            try self.reportAgentHistoryFailure(@errorName(err));
            return;
        };

        self.model.request_lifecycle.tracker.add(
            query.request_id,
            .{
                .agent_history = operation,
            },
        ) catch |err| {
            _ = agent_reading.failed(
                &self.model,
                operation,
                @errorName(err),
            );
            try self.reportAgentHistoryFailure(@errorName(err));
            return;
        };

        self.sendRuntimeAgentHistory(query) catch |err| {
            _ = self.model.request_lifecycle.tracker.take(query.request_id);
            _ = agent_reading.failed(
                &self.model,
                operation,
                @errorName(err),
            );
            try self.reportAgentHistoryFailure(@errorName(err));
            return;
        };

        return;
    }
}

/// Maps attachment limits to a visible failure without changing the existing draft.
/// Example: `try app.attachAgentImage(pane_id, path);`
pub fn attachAgentImage(self: *AttachedClient, pane_id: core.PaneId, path: []const u8) !void {
    _ = self.model.attachAgentImage(pane_id, path) catch |err| {
        try self.publishNotificationNow(
            .{
                .level = .warning,
                .title = "Image was not attached",
                .message = switch (err) {
                    error.TooManyAgentImages => "A message can contain up to four images.",
                    error.InvalidAgentImage => "The clipboard returned an invalid image.",
                    else => "There is not enough memory to retain the image attachment.",
                },
            },
        );
        return;
    };
}

/// Copies and correlates a prompt, preserving the draft until acknowledgement.
/// Example: `try app.submitAgentPrompt(pane_id);`
pub fn submitAgentPrompt(self: *AttachedClient, pane_id: core.PaneId) !void {
    if (self.model.request_lifecycle.tracker.hasPane(.agent_prompt, pane_id)) {
        return;
    }

    const intent = self.model.planAgentPrompt(pane_id) orelse return;
    const request_id = try self.model.request_lifecycle.nextId();
    try self.sendAgentPromptRequest(
        .{
            .request_id = request_id,
            .pane_id = pane_id,
            .pane_generation = intent.pane_generation,
            .text = intent.text,
            .images = intent.images,
            .options = intent.options,
        },
        .{
            .pane_id = pane_id,
            .pane_generation = intent.pane_generation,
            .attachment_generation = intent.attachment_generation,
            .location = intent.location,
            .composer_content_revision = intent.composer_content_revision,
        },
    );
}

/// Example: `try app.interruptAgent(pane_id);`
pub fn interruptAgent(self: *AttachedClient, pane_id: core.PaneId) !void {
    const pending = agentOperation(&self.model, pane_id) orelse return;
    if (self.model.request_lifecycle.tracker.hasPane(.agent_control, pane_id)) {
        return;
    }

    const request_id = try self.model.request_lifecycle.nextId();
    try self.sendRuntimeRequest(
        .{
            .registration = .{
                .request_id = request_id,
                .continuation = .{
                    .agent_control = pending,
                },
            },
            .message = .{
                .agent_interrupt = .{
                    .request_id = request_id,
                    .pane_id = pane_id,
                    .pane_generation = pending.pane_generation,
                },
            },
        },
    );
}

/// Resumes an advertised conversation without consuming the composer's draft.
/// Example: `try app.resumeAgentConversation(pane_id, index);`
pub fn resumeAgentConversation(self: *AttachedClient, pane_id: core.PaneId, index: u8) !void {
    const pending = agentOperation(&self.model, pane_id) orelse return;
    const pane = self.model.agentPane(pane_id) orelse return;
    const snapshot = pane.agent_thread orelse return;
    if (!snapshot.canResume() or index >= snapshot.recent.count or self.model.request_lifecycle.tracker.hasPane(.agent_control, pane_id) or self.model.request_lifecycle.tracker.hasPane(.agent_prompt, pane_id)) {
        return;
    }

    const request_id = try self.model.request_lifecycle.nextId();
    try self.sendRuntimeRequest(
        .{
            .registration = .{
                .request_id = request_id,
                .continuation = .{
                    .agent_control = pending,
                },
            },
            .message = .{
                .agent_resume = .{
                    .request_id = request_id,
                    .pane_id = pane_id,
                    .pane_generation = pending.pane_generation,
                    .expected_revision = snapshot.revision,
                    .conversation_index = index,
                },
            },
        },
    );
}

/// Example: `try app.approveAgent(decision);`
pub fn approveAgent(self: *AttachedClient, decision: data.AgentDecision) !void {
    const pending = agentOperation(&self.model, decision.pane_id) orelse return;
    const pane = self.model.agentPane(decision.pane_id) orelse return;
    const thread = pane.agent_thread orelse return;
    const approval = thread.pending_approval orelse return;
    if (approval.id != decision.approval_id or self.model.request_lifecycle.tracker.hasPane(.agent_control, decision.pane_id)) {
        return;
    }

    const request_id = try self.model.request_lifecycle.nextId();
    try self.sendRuntimeRequest(
        .{
            .registration = .{
                .request_id = request_id,
                .continuation = .{
                    .agent_control = pending,
                },
            },
            .message = .{
                .agent_approval = .{
                    .request_id = request_id,
                    .pane_id = decision.pane_id,
                    .pane_generation = pending.pane_generation,
                    .approval_id = decision.approval_id,
                    .accept = decision.accept,
                },
            },
        },
    );
}

/// Example: `_ = try app.requestTabCreation(command);`
pub fn requestTabCreation(self: *AttachedClient, command: data.RequestTabCreation) !bool {
    if (self.model.request_lifecycle.tracker.has(.tab_operation)) {
        return false;
    }

    try data.label_validation.validate(command.label, .new_tab);
    const plan = self.model.planTabCreation() orelse return false;
    const request_id = try self.model.request_lifecycle.nextId();
    try self.sendCreateTabRequest(
        .{
            .kind = command.kind,
            .request_id = request_id,
            .workspace = plan.workspace,
            .label = command.label,
            .size = data.multiplexer.rectSize(self.geometry().area) orelse return error.TerminalTooSmall,
            .launch = .{
                .cwd = self.options.cwd,
                .cwd_source = plan.cwd_source,
                .arguments = if (command.kind == .agent) &.{} else if (command.arguments.len != 0) command.arguments else self.options.arguments,
            },
        },
    );

    return true;
}

/// Finishes paste and focus, detaches in pane order, then commits detachment.
/// A failure preserves completed effects; the caller chooses recovery or exit.
/// Example: `try app.detachTab(location);`
pub fn detachTab(self: *AttachedClient, location: core.TabLocation) !void {
    const plan = try self.model.planTabDetachment(location);
    if (plan.owns_paste) {
        const outcome = try self.finishPanePaste();
        std.debug.assert(outcome != .ignored);
    }

    if (plan.owns_reported_focus) {
        const outcome = try self.clearReportedFocus();
        std.debug.assert(outcome == .applied);
    }

    for (plan.slice()) |pane| {
        const pending = self.model.request_lifecycle.tracker.hasPane(.attachment, pane.pane_id);
        if (!pane.attached and !pending) {
            continue;
        }

        try self.sendRuntime(
            .{
                .detach_pane = .{
                    .pane_id = pane.pane_id,
                },
            },
        );
        _ = self.model.request_lifecycle.tracker.ignoreAttachment(pane.pane_id);
        try self.graphics.setPaneVisible(pane.pane_id, false);
    }

    try self.model.commitTabDetachment(plan);
}

/// Selects a known inactive workspace only while this connection is idle.
/// Example: `_ = try app.selectWorkspace(.{ .position = 1 });`
pub fn selectWorkspace(self: *AttachedClient, target: data.WorkspaceSelectionTarget) !bool {
    if (!self.model.request_lifecycle.tracker.isEmpty()) {
        return false;
    }

    const workspace = switch (target) {
        .position => |position| self.model.workspace_list_snapshot.workspaceAtPosition(position) orelse return false,
        .workspace => |workspace| workspace,
    };

    if (!self.model.knowsWorkspace(workspace)) {
        return false;
    }

    if (self.model.workspace) |current| {
        switch (current) {
            .workspace => |active| {
                if (active == workspace) {
                    return false;
                }
            },
            .worktree => {},
        }
    }

    _ = try self.requestWorkspaceSwitch(
        .{
            .workspace = workspace,
        },
        .requested_departure,
    );

    return true;
}

/// Opens a workspace using its remembered pane, retaining a single fallback.
/// Example: `_ = try app.requestWorkspace(workspace_id);`
pub fn requestWorkspace(self: *AttachedClient, workspace: core.WorkspaceId) !data.WorkspaceDeparture {
    return self.requestWorkspaceSwitch(
        .{
            .workspace = workspace,
        },
        .requested_departure,
    );
}

/// Validates a workspace creation and retains its launch parameters until confirmation.
/// Example: `_ = try app.requestWorkspaceCreation(.{ .name = "agents" });`
pub fn requestWorkspaceCreation(self: *AttachedClient, command: data.RequestWorkspaceCreation) !bool {
    if (!self.model.request_lifecycle.tracker.isEmpty()) {
        return false;
    }

    try data.label_validation.validate(command.name, .workspace);
    const cwd_source: ?core.PaneId = if (command.cwd.len == 0)
        self.model.planWorkspaceCreation() orelse return false
    else
        null;
    const request_id = try self.model.request_lifecycle.nextId();
    try self.sendCreateWorkspaceRequest(
        .{
            .request_id = request_id,
            .size = data.multiplexer.rectSize(self.geometry().area) orelse return error.TerminalTooSmall,
            .name = command.name,
            .create_cwd = command.create_cwd,
            .launch = .{
                .cwd = if (command.cwd.len != 0) command.cwd else self.options.cwd,
                .cwd_source = cwd_source,
                .arguments = self.options.arguments,
            },
        },
    );

    return true;
}

/// Validates one request and retains its correlation before delivery.
/// Example: `_ = try self.requestTabMove(command);`
pub fn requestTabMove(self: *AttachedClient, command: data.RequestTabMove) !bool {
    if (self.model.request_lifecycle.tracker.has(.tab_operation)) {
        return false;
    }

    const location = command.location orelse self.model.activeTabLocation() orelse return false;
    const workspace = self.model.workspace orelse return false;
    if (!std.meta.eql(workspace, location.workspace) or self.model.tabs.find(location.tab_id) == null) {
        return false;
    }

    if (command.relative_to) |anchor| {
        if (anchor == location.tab_id or self.model.tabs.find(anchor) == null) {
            return false;
        }
    }

    const request_id = try self.model.request_lifecycle.nextId();
    try self.sendRuntimeRequest(
        .{
            .registration = .{
                .request_id = request_id,
                .continuation = .{
                    .move_tab = location,
                },
            },
            .message = .{
                .move_tab = .{
                    .request_id = request_id,
                    .location = location,
                    .direction = command.direction,
                    .relative_to = command.relative_to,
                },
            },
        },
    );

    return true;
}

/// Semantic actions include native conversation readers in copy-mode policy.
/// Example: `_ = self.copyModeActive();`
pub fn copyModeActive(self: *const AttachedClient) bool {
    return self.model.copyModeActive() or self.host_input_source.threadCopyModeActive();
}

/// Leaves copy mode without copying the current selection.
/// Example: `_ = try self.leaveCopyMode();`
pub fn leaveCopyMode(self: *AttachedClient) !data.CopyModeOutcome {
    const outcome = try self.applyCopyMode(.leave);
    const native = self.host_input_source.leaveThreadCopyMode();
    return if (outcome == .unchanged and native) .exited else outcome;
}

/// Example: `_ = try self.applyCopyMode(command);`
pub fn applyCopyMode(self: *AttachedClient, command: data.CopyModeCommand) !data.CopyModeOutcome {
    defer {
        if (command == .cancel_pointer or (command == .pointer and command.pointer.release)) {
            self.model.finishPointerGesture();
        }
    }

    const plan = self.model.planCopyMode(command) orelse return .unchanged;
    if (plan.open_link) |target| {
        _ = try self.openLink(target);

        return .unchanged;
    }

    if (plan.selection) |selection| {
        try self.sendRuntime(
            .{
                .copy_selection = selection,
            },
        );
    }

    const commit = self.model.commitCopyMode(plan) orelse return .unchanged;
    if (commit.viewport) |viewport| {
        try self.deliverPaneViewport(viewport);
    }

    if (plan.search) |direction| {
        _ = self.openNamePrompt(
            .{
                .copy_search = direction,
            },
        );
    }

    return if (commit.active) .changed else .exited;
}

/// Blocks incomplete or oversized pastes while keeping the browser open.
/// Example: `_ = self.canSubmitHistory(selection);`
pub fn canSubmitHistory(self: *AttachedClient, selection: u16) bool {
    const palette = &self.model.history_palette;
    const command = palette.commandAt(selection) orelse {
        self.model.history_palette.setError(if (palette.phase == .loading) "Searching..." else "Command unavailable or capture truncated; cannot paste");
        return false;
    };

    const active = self.model.tabs.activeSlot() orelse return false;
    const pane = data.tab_layout.focusedPaneConst(&self.model, active) orelse return false;
    const pane_input = pane_input_module;
    pane_input.validateHistoryText(command, pane.input_modes.bracketed_paste) catch |err| {
        self.model.history_palette.setError(if (err == error.UnframedHistoryText) "Multiline/tab paste requires shell bracketed-paste support" else "Command contains terminal controls; cannot paste");
        return false;
    };

    const slots = (command.len + 13 + data.input_limits.max_encoded_bytes - 1) / data.input_limits.max_encoded_bytes;
    if (self.runtime_transport.outbox.availableCapacity() < slots + 1) {
        self.model.history_palette.setError("Input is busy; retry the command");
        return false;
    }

    return true;
}

/// Publishes one owned notice through the application boundary.
/// Example: `_ = try self.publishNotification(now_ns, input);`
pub fn publishNotification(self: *AttachedClient, now_ns: u64, input: data.NotificationInput) !data.NotificationPublication {
    const publication = self.model.publishNotification(now_ns, input);
    try self.scheduleNotificationTimer();
    try self.deliverHostNotification(input);
    return publication;
}

/// Publishes one local notice at the current client monotonic timestamp.
/// Example: `try self.publishNotificationNow(input);`
pub fn publishNotificationNow(self: *AttachedClient, input: data.NotificationInput) !void {
    _ = try self.publishNotification(core.monotonic(self.io), input);
}

/// Completes one physical timer before advancing and rearming notification
/// state in the client model.
/// Example: `_ = try self.completeNotificationTick(result);`
pub fn completeNotificationTick(self: *AttachedClient, result: anyerror!void) !?data.NotificationChange {
    try self.model.notification_scheduler.complete(result);

    return self.advanceNotifications(core.monotonic(self.io));
}

/// Activates one current notification and follows its target at the client
/// monotonic timestamp.
/// Example: `_ = try self.activateNotificationNow(id);`
pub fn activateNotificationNow(self: *AttachedClient, id: data.NotificationId) !?data.NotificationActivation {
    return self.activateNotification(id, core.monotonic(self.io));
}

/// Dismisses one current notification at the client monotonic timestamp.
/// Example: `_ = try self.dismissNotificationNow(id);`
pub fn dismissNotificationNow(self: *AttachedClient, id: data.NotificationId) !?data.NotificationChange {
    return self.dismissNotification(id, core.monotonic(self.io));
}

/// Releases one playback worker and schedules its coalesced successor.
/// Host playback errors drop that sound without stopping the queue.
/// Example: `try self.completeAgentSound(result);`
pub fn completeAgentSound(self: *AttachedClient, result: anyerror!void) !void {
    _ = result catch {};
    const next = self.model.sound_playback.complete() orelse return;

    try self.startAgentSound(next);
}

/// Commits focus before synchronizing attachments and child focus.
/// Example: `_ = try self.applyPaneFocus(command);`
pub fn applyPaneFocus(self: *AttachedClient, command: data.PaneFocusRequest) !?data.PaneFocus {
    const focus = self.model.focusPane(command) orelse return null;
    try self.deliverPaneFocus(focus, command.area);

    return focus;
}

/// Completes one timer, advances the model and rearms only active animation.
/// Example: `_ = try self.completeSidebarAnimationTick(result);`
pub fn completeSidebarAnimationTick(self: *AttachedClient, result: anyerror!void) !?data.SidebarAnimationChange {
    try self.model.sidebar_animation_scheduler.complete(result);
    const change = self.model.advanceSidebarAnimation() orelse return null;
    try self.scheduleSidebarAnimation();
    return change;
}

/// Selects canonical identity, retires previous input authorities and requests current membership. Example: `_ = try select(client, command);`
/// Example: `_ = try app.selectTab(command);`
pub fn selectTab(self: *AttachedClient, command: data.SelectTab) !?data.TabSelection {
    if (self.model.request_lifecycle.tracker.has(.tab_snapshot)) {
        return null;
    }

    const selection = self.model.selectTab(command.target) catch |err| switch (err) {
        error.NoActiveTab, error.TabNotFound => return null,
    } orelse return null;
    try self.detachTab(selection.previous);

    const selected = self.model.tabs.find(selection.selected.tab_id) orelse return error.StaleTabSelection;
    var panes = self.model.panes.iterate(self.model.tabs.location[selected].tab_id);
    while (panes.next()) |pane| {
        try self.graphics.setPaneVisible(pane.id, true);
    }

    try self.synchronizeActivePane();
    try self.requestTabSnapshot(selection.selected);
    return selection;
}

/// Changes visibility and synchronizes pane geometry. Example: `_ = try toggle(client);`.
/// Example: `_ = try app.toggleSidebar();`
pub fn toggleSidebar(self: *AttachedClient) !data.SidebarLayout {
    const change = self.model.toggleSidebar();
    try self.deliverSidebarLayout(change);
    return change;
}

/// Changes the exact or stepped width. Example: `_ = try resize(client, .{ .exact = 73 });`.
/// Example: `_ = try app.resizeSidebar(requested);`
pub fn resizeSidebar(self: *AttachedClient, requested: data.SidebarResize) !?data.SidebarLayout {
    const change = switch (requested) {
        .exact => |width| self.model.setSidebarWidth(width),
        .direction => |direction| self.model.stepSidebarWidth(direction),
    } orelse return null;

    try self.deliverSidebarLayout(change);
    return change;
}

/// Coalesces the complete, canonical layout of the current workspace into the
/// runtime outbox. Tabs without a runtime snapshot are omitted until known.
/// Example: `try app.synchronizeClientLayout();`
pub fn synchronizeClientLayout(self: *AttachedClient) !void {
    if (!self.model.client_layouts.snapshot_received) {
        return;
    }

    const version = layout_updates.captureVersion(&self.model) orelse return;
    if (self.model.client_layouts.last_sent) |last| {
        if (last.eql(&version)) {
            return;
        }
    }

    var nodes: [core.max_client_layout_nodes]core.ClientLayoutNode = undefined;
    var tabs: [core.max_client_layout_tabs]core.ClientTabLayout = undefined;
    const layout_update = layout_updates.buildUpdate(
        &self.model,
        &nodes,
        &tabs,
    ) orelse return;
    self.sendRuntimeClientLayout(layout_update) catch |err| switch (err) {
        error.ClientOutboxFull, error.TooManyPendingClientLayouts => return,
        else => return err,
    };

    self.model.client_layouts.last_sent = version;
}

/// Delivers one user-input command through the application boundary.
/// Example: `_ = try app.sendPaneInput(command);`
pub fn sendPaneInput(self: *AttachedClient, command: data.PaneInputCommand) !?data.PaneInputDelivery {
    const started = core.now(self.io);

    const plan = self.model.planPaneInput(command.target) orelse return null;
    var encoded: [32]u8 = undefined;
    const prepared: data.PreparedPaneInput = switch (command.payload) {
        .bytes => |value| .{
            .source = command.source,
            .bytes = value,
        },
        .key => |value| .{
            .source = command.source,
            .bytes = try encoding_support.encodeKey(
                &encoded,
                value,
                plan.input_modes,
            ),
            .restore_viewport = value.phase != .release,
            .empty_is_noop = true,
        },
    };
    if (prepared.bytes.len == 0 and prepared.empty_is_noop) {
        return null;
    }

    return self.recordPaneInput(started, try self.deliverPaneInput(plan, prepared));
}

/// Starts one pane-owned paste against the current focused target.
/// Example: `_ = try app.startPanePaste();`
pub fn startPanePaste(self: *AttachedClient) !data.PanePasteOutcome {
    const session = self.model.beginPanePaste() orelse return .ignored;
    errdefer {
        const rolled_back = self.model.finishPanePaste(session);
        std.debug.assert(rolled_back);
    }

    if (!session.bracketed_paste) {
        return .applied;
    }

    if (!try self.deliverPanePaste(
        .{
            .marker = .{
                .session = session,
                .boundary = .start,
            },
        },
    )) {
        const rolled_back = self.model.finishPanePaste(session);
        std.debug.assert(rolled_back);
        return .unavailable;
    }

    return .applied;
}

/// Delivers one host paste chunk to the captured target.
/// Example: `_ = try app.appendPanePaste(text);`
pub fn appendPanePaste(self: *AttachedClient, text: []const u8) !data.PanePasteOutcome {
    const session = self.model.pane_paste orelse return .ignored;
    const delivered = try self.deliverPanePaste(
        .{
            .content = .{
                .session = session,
                .text = text,
            },
        },
    );

    return if (delivered) .applied else .unavailable;
}

/// Finishes the current pane paste and releases its captured identity.
/// Example: `_ = try app.finishPanePaste();`
pub fn finishPanePaste(self: *AttachedClient) !data.PanePasteOutcome {
    const session = self.model.pane_paste orelse return .ignored;
    defer {
        const finished = self.model.finishPanePaste(session);
        std.debug.assert(finished);
    }

    if (!session.bracketed_paste) {
        return .applied;
    }

    const delivered = try self.deliverPanePaste(
        .{
            .marker = .{
                .session = session,
                .boundary = .finish,
            },
        },
    );

    return if (delivered) .applied else .unavailable;
}

/// Resolves a pointer event or focused scroll without exposing pane storage
/// or child mouse modes to the caller.
/// Example: `_ = try app.inputPaneMouse(tab, command);`
pub fn inputPaneMouse(self: *AttachedClient, tab: usize, command: data.PaneMouseCommand) !data.PaneMouseOutcome {
    const area = self.geometry().area;
    const resolved: data.Resolved = switch (command) {
        .pointer => |pointer| .{
            .plan = data.tab_layout.planPaneMouse(&self.model, tab, pointer.event, area) orelse return .ignored,
            .pointer = pointer,
        },
        .focused_scroll => |direction| focused: {
            const plan = data.tab_layout.planFocusedPaneMouse(&self.model, tab, area) orelse return .ignored;
            const host_size = self.model.host.host_size;

            break :focused .{
                .plan = plan,
                .pointer = .{
                    .event = .{
                        .x = plan.content.x,
                        .y = plan.content.y,
                        .kind = if (direction == .up) .scroll_up else .scroll_down,
                        .button = if (direction == .up) 64 else 65,
                    },
                    .exterior_pixels = false,
                    .cell_width_px = host_size.cell_width_px,
                    .cell_height_px = host_size.cell_height_px,
                },
            };
        },
    };
    const plan = resolved.plan;
    const pointer = resolved.pointer;

    const forced_selection = pointer.event.button & 4 != 0;
    if (pointer.event.kind == .press and pointer.event.button & 0b11 == 0 and
        (plan.protocol.tracking == .none or forced_selection))
    {
        try self.applyPaneMouseEffect(
            .{
                .selection = .{
                    .plan = plan,
                    .command = pointer,
                },
            },
        );
        return .selection_started;
    }

    const wheel_delta: ?i32 = switch (pointer.event.kind) {
        .scroll_up => -3,
        .scroll_down => 3,
        else => null,
    };

    const tracked = plan.protocol.sgr and mouse_protocol_module.tracked(plan.protocol.tracking, pointer.event.kind);

    if (wheel_delta) |delta| {
        if (!tracked) {
            if (plan.alternate_scroll and plan.at_bottom) {
                try self.applyPaneMouseEffect(
                    .{
                        .alternate_scroll = .{
                            .pane_id = plan.pane_id,
                            .delta = delta,
                        },
                    },
                );
                return .alternate_scroll_selected;
            }

            try self.applyPaneMouseEffect(
                .{
                    .viewport = .{
                        .pane_id = plan.pane_id,
                        .delta = delta,
                    },
                },
            );
            return .viewport_selected;
        }
    }

    if (!tracked) {
        return .ignored;
    }

    try self.applyPaneMouseEffect(
        .{
            .report = .{
                .plan = plan,
                .command = pointer,
            },
        },
    );
    return .report_selected;
}

/// Delivers a host-retained gesture to its original pane after the host has
/// checked attachment identity and projected its current rectangle.
/// Example: `try reportRetained(client, report);`
/// Example: `try app.reportRetainedPaneMouse(report);`
pub fn reportRetainedPaneMouse(self: *AttachedClient, report: data.ReportEffect) !void {
    return self.deliverPaneMouseReport(report, true);
}

/// Routes one semantic key or borrowed byte slice to a single current owner.
/// Example: `_ = try app.routeKeyInput(command);`
pub fn routeKeyInput(self: *AttachedClient, command: data.KeyRoutingCommand) !data.KeyRoutingOutcome {
    const current = self.keyRoutingAuthority();
    const outcome = switch (command) {
        .bytes => |bytes| if (bytes.len == 0) data.KeyRoutingOutcome{
            .owner = .ignored,
        } else (try self.routeCurrentKey(command, current)).outcome,
        .key => |key| try self.routePhysicalKey(key, current),
    };
    self.telemetry.metrics.key_lease_overflows +%= @intFromBool(outcome.lease_overflow);
    return outcome;
}

/// Opens the command palette with `prefix` already typed. A `?` palette
/// starts with a cleared suggestion, like `suggestions.begin`.
/// Example: `_ = app.beginCommandPalette(prefix);`
pub fn beginCommandPalette(self: *AttachedClient, prefix: data.CommandPalettePrefix) bool {
    if (!self.openNamePrompt(
        .{
            .palette = prefix,
        },
    )) {
        return false;
    }

    if (prefix == .suggest) {
        self.model.suggestion.begin();
    }

    return true;
}

/// Chooses one visible list row with the pointer and submits it, exactly as
/// moving the selection there and pressing Enter would.
/// Example: `try app.choosePromptRow(index);`
pub fn choosePromptRow(self: *AttachedClient, index: u16) !void {
    self.model.name_prompt.select(index);
    self.constrainPickerSelection();
    _ = try self.inputPrompt(
        .{
            .key = .{
                .code = .enter,
            },
        },
    );
}

/// Selects a command from a delivered history page without pasting or running
/// it. Example: `try selectHistoryRow(client, index, page_revision);`.
/// Example: `try app.selectHistoryRow(index, revision);`
pub fn selectHistoryRow(self: *AttachedClient, index: u16, revision: u64) !void {
    if (!history_browser.select(
        &self.model,
        index,
        revision,
    )) {
        return;
    }

    try self.refreshHistoryInspection();
}

/// Scrolls output by logical lines and reapplies the adapter's exact bound.
/// Example: `try scrollHistoryInspection(client, 1);`.
/// Example: `try app.scrollHistoryInspection(lines);`
pub fn scrollHistoryInspection(self: *AttachedClient, lines: i16) !void {
    history_browser.scrollInspection(&self.model, lines);
    try self.refreshHistoryInspection();
}

/// Accepts a directory row only while its landed listing is still current.
/// Clicking a folder completes the path without submitting the context form.
/// Example: `try chooseDirectory(client, index, listing_revision);`
/// Example: `try app.chooseDirectory(index, revision);`
pub fn chooseDirectory(self: *AttachedClient, index: u16, revision: u64) !void {
    const prompt = self.model.name_prompt.currentConst() orelse return;
    const completion = &self.model.path_completion;
    if (prompt.form() == null or completion.version() != revision or completion.pending != .none or index >= completion.entries().len) {
        return;
    }

    _ = try self.inputPrompt(
        .{
            .command = .{
                .focus_field = .directory,
            },
        },
    );
    self.model.name_prompt.select(index);
    _ = try self.inputPrompt(
        .{
            .command = .tab,
        },
    );
}

/// Applies one semantic event as a bounded prompt command. Accepted
/// submissions close the prompt after delivery; blocked or failed
/// effects leave the prompt intact.
/// Example: `_ = try app.inputPrompt(input);`
pub fn inputPrompt(self: *AttachedClient, input: name_prompts.Input) !data.PromptOutcome {
    const before = promptListSnapshot(&self.model.name_prompt);
    const directory_before = promptDirectoryVersion(&self.model.name_prompt);
    const command = name_prompts.commandFor(input);
    const outcome = if (command) |value| try self.applyPromptCommand(value) else .unchanged;
    try self.refreshPromptHistory(before);
    try self.navigateHistoryPage();
    if (outcome == .completion_requested) {
        try self.acceptPathCompletion();
    } else if (outcome == .cancelled or outcome == .finished) {
        self.closePathCompletion();
    } else if (directory_before != null and !std.meta.eql(directory_before, promptDirectoryVersion(&self.model.name_prompt))) {
        try self.refreshPathCompletion();
    }
    self.constrainPickerSelection();
    try self.refreshHistoryInspection();
    self.discardEditedSuggestion(before);
    if (outcome == .finished) {
        var submission = before;
        submission.alternate = self.list_submission_alternate;
        self.list_submission_alternate = false;
        try self.finishPromptList(submission);
    }
    if (outcome == .removed and before.kind == .history) {
        try self.deleteHistorySelection(before.selection);
    }
    return outcome;
}

/// Checks current input authority and initializes the prompt from canonical model state.
/// Example: `const opened = app.openNamePrompt(.rename_active_tab);`
pub fn openNamePrompt(self: *AttachedClient, intent: name_prompt_opening.Intent) bool {
    if (self.model.panePasteActive()) {
        return false;
    }
    if (intent == .copy_search) {
        if (!self.model.copyModeActive()) {
            return false;
        }

        self.model.name_prompt.begin(
            .{
                .copy_search = intent.copy_search,
            },
        );
        return true;
    }
    if (self.model.copyModeActive()) {
        return false;
    }

    const command: data.PromptBegin = switch (intent) {
        .create_workspace => create: {
            if (!self.model.request_lifecycle.tracker.isEmpty()) {
                return false;
            }
            if (self.model.planWorkspaceCreation() == null) {
                return false;
            }

            break :create .create_workspace;
        },
        .rename_workspace => rename: {
            const workspace = self.model.workspace orelse return false;
            break :rename .{
                .rename_workspace = .{
                    .workspace = workspace,
                    .name = self.model.workspaceName(),
                },
            };
        },
        .rename_active_tab => rename: {
            const active = self.model.tabs.activeSlot() orelse return false;
            break :rename name_prompt_opening.renameTab(self.model.tabs.location[active].tab_id, data.tab_label.text(&self.model, active));
        },
        .rename_tab => |tab_id| rename: {
            const tab = self.model.tabs.find(tab_id) orelse return false;
            break :rename name_prompt_opening.renameTab(tab_id, data.tab_label.text(&self.model, tab));
        },
        .goto_picker => .goto_picker,
        .history_palette => .history_palette,
        .suggest_palette => .suggest_palette,
        .palette => |prefix| .{
            .palette = prefix,
        },
        .copy_search => unreachable,
    };

    self.model.name_prompt.begin(command);
    return true;
}

/// Deletes the paired child marker and then retires one local preview.
/// Example: `_ = try app.dismissAttachment(id);`
pub fn dismissAttachment(self: *AttachedClient, id: data.AttachmentId) !bool {
    const command = self.planAttachmentRemoval(id) orelse return false;
    try self.deliverAttachmentRemoval(command);
    return self.attachment_shelf.remove(id) orelse false;
}

/// Records a marker deletion only for the visible attachment target and compatible key.
/// Example: `app.expectMarkerDeletion(pane_id, command);`
pub fn expectMarkerDeletion(self: *AttachedClient, pane_id: core.PaneId, command: data.KeyRoutingCommand) void {
    const key = switch (command) {
        .bytes => return,
        .key => |value| value,
    };
    const target = self.attachment_catalog.visibleTarget() orelse return;
    if (target.pane_id != pane_id) {
        return;
    }

    const policy = self.attachmentMarkerPolicy(target) orelse return;
    if (!attachment_prompt.editsMarkers(policy, key)) {
        return;
    }

    self.attachment_catalog.expectMarkerDeletion(target);
}

/// Resolves one reload completion, applies its outcome and rearms the watcher.
/// Example: `_ = try app.completeConfigReload(result);`
pub fn completeConfigReload(self: *AttachedClient, result: anyerror!config_reload.ConfigReload) !data.ConfigReloadOutcome {
    const reload = try result;
    const outcome: data.ConfigReloadOutcome = switch (config_reload.resolve(
        &self.reload,
        .{
            .gpa = self.gpa,
            .reload = reload,
            .checks = .{
                .kitty_support = self.model.host.host_capabilities.images,
                .sidebar_renderer_locked = self.options.sidebar_renderer_locked,
                .current_sidebar = self.model.config.sidebar_rendering,
            },
        },
    )) {
        .unchanged => .unchanged,
        .rejected => |diagnostic| rejected: {
            _ = try client_diagnostic.replace(
                &self.model,
                .{
                    .diagnostic = diagnostic,
                    .invalid_fallback = client_diagnostic.formatted(
                        "configuration reload failed: invalid diagnostic text",
                        .{},
                    ),
                },
            );
            try self.publishNotificationNow(
                .{
                    .level = .failure,
                    .title = "Configuration rejected",
                    .message = self.model.diagnostic() orelse return error.ClientDiagnosticMissing,
                    .duration_ns = 7 * std.time.ns_per_s,
                },
            );
            break :rejected .rejected;
        },
        .adopted => |adoption| adopted: {
            const commit = try self.adoptConfiguration(adoption);
            try self.publishNotificationNow(
                .{
                    .level = .success,
                    .title = "Configuration reloaded",
                    .message = "The new settings are active",
                },
            );
            break :adopted .{
                .adopted = commit,
            };
        },
    };
    try self.scheduleConfigReload();
    return outcome;
}

/// Consumes one worker completion and applies its authorized action batch.
/// Example: `_ = try app.completePluginAction(completion);`
pub fn completePluginAction(self: *AttachedClient, completion: data.PluginActionsCompletion) !bool {
    const command: plugin_action.CompletionCommand = if (completion.result) |result|
        .{
            .succeeded = .{
                .execution_id = completion.execution_id,
                .package_index = result.package_index,
                .plugin_id = result.plugin_id,
                .digest = result.digest,
                .batch = &result.batch,
            },
        }
    else |err|
        .{
            .failed = .{
                .execution_id = completion.execution_id,
                .reason = err,
            },
        };

    const execution = self.model.plugins.finishPluginExecution(command.executionId()) orelse
        return self.reportPluginCompletion(.ignored);
    if (execution.configuration_generation != self.model.configuration_generation) {
        return self.reportPluginCompletion(.stale);
    }

    return self.reportPluginCompletion(switch (command) {
        .failed => |failure| .{
            .worker_failed = failure.reason,
        },
        .succeeded => |result| result: {
            authorizePluginResult(self.plugin_registry, result) catch |err| {
                break :result .{
                    .authorization_failed = err,
                };
            };

            _ = self.model.clearDiagnostic();
            const disposition = try self.applyPluginBatch(result.batch);
            break :result switch (disposition) {
                .continue_client => .applied,
                .exit_client => .exit,
            };
        },
    });
}

/// Lands one worker result. A result for another execution, or for a query
/// the form already moved past, is released without touching the model.
/// Example: `try app.completePathCompletion(completion);`
pub fn completePathCompletion(self: *AttachedClient, completion: data.PathCompletionCompletion) !void {
    const result = completion.result catch null;
    defer if (result) |owned| self.gpa.destroy(owned);
    const completion_state = &self.model.path_completion;
    if (!completion_state.retire(completion.execution_id)) {
        return;
    }
    if (completion_state.superseded() or self.model.name_prompt.currentConst() == null) {
        try self.startPathCompletion();
        return;
    }
    if (result) |owned| {
        completion_state.land(.{
            .query = completion_state.inflightSlice(),
            .result = owned,
        });
    } else {
        self.model.path_completion.invalidate();
    }
}

/// Consumes one worker event and adopts only its current exact result.
/// Example: `try app.completeClipboardCapture(completion);`
pub fn completeClipboardCapture(self: *AttachedClient, completion: data.Completion) !void {
    var owned_capture: ?*data.Capture = null;
    defer if (owned_capture) |capture| {
        capture.deinit(self.gpa);
    };

    const command: clipboard_image.CompletionCommand = if (completion.result) |completed| completed: {
        const capture = self.model.clipboard.take(completed);
        owned_capture = capture;
        break :completed .{
            .succeeded = .{
                .execution_id = completion.execution_id,
                .result_id = @enumFromInt(capture.request.sequence),
                .target = capture.request.target,
            },
        };
    } else |err| .{
        .failed = .{
            .execution_id = completion.execution_id,
            .reason = err,
        },
    };

    const capture = self.model.clipboard.finish(command.executionId()) orelse
        return;

    const outcome: clipboard_image.CompletionOutcome = switch (command) {
        .failed => |failure| clipboard_image.classifyFailure(failure.reason),
        .succeeded => |result| result: {
            if (result.result_id != capture.id or !std.meta.eql(result.target, capture.target)) {
                break :result .stale;
            }

            const current = self.model.focusedAttachmentTarget() orelse
                break :result .stale;
            if (!std.meta.eql(current, capture.target)) {
                break :result .stale;
            }

            const layout_changed = self.adoptClipboardCapture(owned_capture.?) catch |err| {
                break :result .{
                    .adoption_failed = err,
                };
            };
            owned_capture = null;
            if (layout_changed) {
                if (self.model.tabs.activeSlot()) |tab| {
                    try self.resizeAttachedPanes(tab, self.geometry().area);
                }
            }

            break :result .applied;
        },
    };
    try self.reportClipboardCapture(outcome);
}

/// Resolves one sidebar agent key and applies its local navigation or handoff.
/// Example: `_ = try app.navigateAgent(key);`
pub fn navigateAgent(self: *AttachedClient, key: data.AgentKey) !AgentNavigationOutcome {
    const plan = self.model.planAgentNavigation(key) orelse return .ignored;
    return switch (plan) {
        .local => |local| local: {
            if (local.select_tab) |tab_id| {
                if (try self.selectTab(
                    .{
                        .target = .{
                            .tab_id = tab_id,
                        },
                    },
                ) == null) {
                    break :local .ignored;
                }
            }
            _ = try self.applyPaneFocus(
                .{
                    .target = .{
                        .pane_id = local.pane_id,
                    },
                    .area = self.geometry().area,
                },
            );
            break :local .focused;
        },
        .handoff => |handoff| handoff: {
            if (!self.model.request_lifecycle.tracker.isEmpty()) {
                break :handoff .ignored;
            }
            _ = try self.requestWorkspacePane(handoff.pane_id, handoff.fallback_workspace);
            break :handoff .handoff_requested;
        },
    };
}

/// Copies and coalesces one complete reconnectable client layout.
///
/// ```zig
/// try self.sendRuntimeClientLayout(update);
/// ```
fn sendRuntimeClientLayout(self: *AttachedClient, layout_update: core.ClientLayoutUpdate) !void {
    try self.runtime_transport.outbox.pushClientLayout(layout_update);
    try self.startRuntimeSend();
}

/// Requests a canonical snapshot with its exact target retained until the reply.
/// Example: `try self.requestTabSnapshot(location);`
fn requestTabSnapshot(self: *AttachedClient, location: core.TabLocation) !void {
    const request_id = try self.model.request_lifecycle.nextId();
    try self.sendRuntimeRequest(
        .{
            .registration = .{
                .request_id = request_id,
                .continuation = .{
                    .tab_snapshot = location,
                },
            },
            .message = .{
                .request_tab_snapshot = .{
                    .request_id = request_id,
                    .location = location,
                },
            },
        },
    );
}

/// Requests a canonical snapshot with its exact target retained until the reply.
/// Example: `try self.requestWorkspaceSnapshot(workspace);`
fn requestWorkspaceSnapshot(self: *AttachedClient, workspace: core.WorkspaceLocation) !void {
    const request_id = try self.model.request_lifecycle.nextId();
    try self.sendRuntimeRequest(
        .{
            .registration = .{
                .request_id = request_id,
                .continuation = .{
                    .workspace_snapshot = workspace,
                },
            },
            .message = .{
                .request_workspace_snapshot = .{
                    .request_id = request_id,
                    .workspace = workspace,
                },
            },
        },
    );
}

/// Connects visible detached panes after canonical membership is loaded.
/// Pending attachments are coalesced; failed delivery rolls back its correlation.
/// Example: `if (tab.snapshot_loaded) { try self.attachVisiblePanes(tab, area); }`
fn attachVisiblePanes(self: *AttachedClient, tab: usize, area: core.Rect) !void {
    std.debug.assert(self.model.tabs.snapshot_loaded[tab]);
    var panes = self.model.panes.iterate(self.model.tabs.location[tab].tab_id);

    while (panes.next()) |pane| {
        if (pane.attached or self.model.request_lifecycle.tracker.hasPane(.attachment, pane.id)) {
            continue;
        }

        const size = data.tab_layout.contentSize(&self.model, tab, pane.id, area) orelse continue;
        const request_id = try self.model.request_lifecycle.nextId();
        try self.sendRuntimeRequest(
            .{
                .registration = .{
                    .request_id = request_id,
                    .continuation = .{
                        .attach_pane = .{
                            .pane_id = pane.id,
                            .location = self.model.tabs.location[tab],
                        },
                    },
                },
                .message = .{
                    .open_pane = .{
                        .request_id = request_id,
                        .target = .{
                            .pane = pane.id,
                        },
                        .size = size,
                        .launch = null,
                    },
                },
            },
        );
    }
}

/// Example: `try app.recoverTabSnapshot(location);`
fn recoverTabSnapshot(self: *AttachedClient, location: core.TabLocation) !TabSnapshotRecovery {
    if (self.model.request_lifecycle.tracker.has(.tab_snapshot)) {
        return .coalesced;
    }

    try self.requestTabSnapshot(location);
    return .requested;
}

/// Example: `_ = try app.requestTabRename(command);`
fn requestTabRename(self: *AttachedClient, command: data.RequestRenameTab) !bool {
    if (self.model.request_lifecycle.tracker.has(.tab_operation)) {
        return false;
    }

    try data.label_validation.validate(command.label, .renamed_tab);
    const location = self.model.tabLocation(command.tab_id) orelse return false;
    const request_id = try self.model.request_lifecycle.nextId();
    try self.sendTabRenameRequest(
        .{
            .request_id = request_id,
            .location = location,
            .label = command.label,
        },
        .{
            .rename_tab = location,
        },
    );

    return true;
}

/// Opens an exact remote pane with the containing workspace as optional fallback.
/// Example: `_ = try app.requestWorkspacePane(pane_id, workspace_id);`
fn requestWorkspacePane(self: *AttachedClient, pane_id: core.PaneId, fallback_workspace: ?core.WorkspaceId) !data.WorkspaceDeparture {
    return self.requestWorkspaceSwitch(
        .{
            .pane = .{
                .pane_id = pane_id,
                .fallback_workspace = fallback_workspace,
            },
        },
        .requested_departure,
    );
}

/// Sends one bounded history query in the palette's current scope and
/// awaits only its reply. A scope whose value cannot be resolved from the
/// committed model falls back to global.
/// Example: `try self.queryHistory(query);`
fn queryHistory(self: *AttachedClient, query: []const u8) !void {
    history_browser.restart(&self.model);
    try self.requestHistoryPage(query);
}

/// Loads selected detail only on demand and contains expected queue saturation.
/// Example: `try self.refreshHistoryInspection();`
fn refreshHistoryInspection(self: *AttachedClient) !void {
    for (0..2) |_| {
        const next = history_browser.nextRead(&self.model);
        if (self.chrome.inspectionScrollLimit()) |limit| {
            history_browser.constrainInspection(&self.model, limit);
        }

        const read = next orelse return;
        const request_id = try self.model.request_lifecycle.nextId();
        if (!history_browser.requestRead(
            &self.model,
            core.raw(request_id),
            read,
        )) {
            return;
        }

        const message: data.outbox_support.Message = switch (read.kind) {
            .command => .{
                .query_history = .{
                    .request_id = request_id,
                    .entry_id = read.id,
                    .limit = 1,
                },
            },
            .output => .{
                .read_history_output = .{
                    .request_id = request_id,
                    .id = read.id,
                },
            },
        };

        try self.enqueueHistoryRequest(message, request_id);
    }
}

/// Pages in bounded batches while retaining the first query's insertion boundary.
/// Example: `try self.navigateHistoryPage();`
fn navigateHistoryPage(self: *AttachedClient) !void {
    if (history_browser.navigate(&self.model)) {
        try self.requestHistoryPage(self.model.name_prompt.currentConst().?.field.text());
    }
}

/// Pastes the selected command into the focused pane, optionally running it
/// by appending Enter. Runs after the prompt closed, because
/// `planPaneInput(.focused)` refuses input while a prompt is active; an
/// empty result list means there is nothing to paste.
/// Example: `try self.pasteHistorySelection(request);`
fn pasteHistorySelection(self: *AttachedClient, request: data.HistoryPasteRequest) !void {
    const palette = &self.model.history_palette;
    if (palette.len == 0) {
        return;
    }

    const index = @min(request.selection, @as(u16, palette.len) - 1);
    const command = palette.commandAt(index) orelse return;
    _ = try self.pasteHistoryCommand(command, request.run);
}

/// Sends one exact-entry deletion for the palette's selected row. The
/// runtime answers with `history_pruned`, which requeries the palette so
/// the row disappears only once it is actually gone.
/// Example: `try self.deleteHistorySelection(selection);`
fn deleteHistorySelection(self: *AttachedClient, selection: u16) !void {
    const request_id = try self.model.request_lifecycle.nextId();
    const id = history_browser.requestDelete(
        &self.model,
        core.raw(request_id),
        selection,
    ) orelse return;
    try self.enqueueHistoryRequest(
        .{
            .delete_history = .{
                .request_id = request_id,
                .id = id,
            },
        },
        request_id,
    );
}

/// Sends one bounded request for the focused pane and awaits only its
/// reply. Without a focused pane there is nothing to give context, so the
/// palette shows a failure instead of asking.
/// Example: `try self.requestSuggestion(text);`
fn requestSuggestion(self: *AttachedClient, text: []const u8) !void {
    const pane_id = suggestionPane(&self.model) orelse {
        self.model.suggestion.expect(1);
        _ = self.model.suggestion.apply(
            .{
                .request_id = @enumFromInt(1),
                .status = .failed,
            },
        );
        return;
    };

    const request_id = try self.model.request_lifecycle.nextId();
    var owned: data.OwnedSuggestion = .{
        .request_id = request_id,
        .pane_id = pane_id,
        .text_len = @intCast(@min(text.len, data.OwnedSuggestion.max_text_bytes)),
    };
    @memcpy(owned.text[0..owned.text_len], text[0..owned.text_len]);

    self.model.suggestion.expect(core.raw(request_id));
    try self.sendRuntime(
        .{
            .suggest_command = owned,
        },
    );
}

/// Pastes the landed suggestion into the focused pane. Runs after the
/// prompt closed, because `planPaneInput(.focused)` refuses input while a
/// prompt is active. Nothing is pasted unless a suggestion is ready.
/// Example: `try self.pasteSuggestion();`
fn pasteSuggestion(self: *AttachedClient) !void {
    const state = &self.model.suggestion;
    if (state.phase != .ready) {
        return;
    }

    _ = try self.pasteExpression(state.textSlice());
}

/// Registers correlation before copying the request; failed delivery removes only that registration.
/// Example: `try self.sendNotificationRequest(request);`
fn sendNotificationRequest(self: *AttachedClient, request: core.ShowNotification) !void {
    try self.model.request_lifecycle.tracker.add(request.request_id, .notification);
    errdefer _ = self.model.request_lifecycle.tracker.take(request.request_id);
    try self.runtime_transport.outbox.pushNotification(request);
    try self.startRuntimeSend();
}

/// Delivers resources for a committed focus, including newly revealed panes. Example: `try self.deliverPaneFocus(focus, area);`
fn deliverPaneFocus(self: *AttachedClient, focus: data.PaneFocus, area: core.Rect) !void {
    const active = self.model.tabs.activeSlot() orelse return error.StalePaneFocus;
    if (!std.meta.eql(self.model.tabs.location[active], focus.location) or
        self.model.tabs.layout[active].focused() != focus.focused or
        self.model.version().panes != focus.panes_revision)
    {
        return error.StalePaneFocus;
    }

    try self.synchronizeActivePane();
    if (!focus.geometry_changed) {
        return;
    }

    self.model.to_host.invalidate_placements = true;
    try self.resizeAttachedPanes(active, area);

    if (self.model.tabs.snapshot_loaded[active]) {
        try self.attachVisiblePanes(active, area);
    }
}

/// Registers correlation before copying the request; failed delivery removes only that registration.
/// Example: `try self.sendCreateWorkspaceRequest(request);`
fn sendCreateWorkspaceRequest(self: *AttachedClient, request: core.CreateWorkspace) !void {
    try self.model.request_lifecycle.tracker.add(
        request.request_id,
        .{
            .create_workspace = request.size,
        },
    );
    errdefer _ = self.model.request_lifecycle.tracker.take(request.request_id);
    try self.runtime_transport.outbox.pushCreateWorkspace(request);
    try self.startRuntimeSend();
}

/// Counts the deliveries needed to detach one tab, including pending attachments.
/// Example: `const required = try app.tabDetachmentCapacity(location);`
fn tabDetachmentCapacity(self: *const AttachedClient, location: core.TabLocation) !usize {
    const plan = try self.model.planTabDetachment(location);
    var required = @as(usize, @intFromBool(plan.paste_marker_required));
    required += @intFromBool(plan.focus_out_required);
    for (plan.slice()) |pane| {
        required += @intFromBool(pane.attached or self.model.request_lifecycle.tracker.hasPane(.attachment, pane.pane_id));
    }

    return required;
}

/// Copies a page cursor before its reading window can change.
/// Example: `try self.sendRuntimeAgentHistory(request);`
fn sendRuntimeAgentHistory(self: *AttachedClient, request: core.QueryAgentHistory) !void {
    try self.runtime_transport.outbox.pushAgentHistory(request);
    try self.startRuntimeSend();
}

/// Pins a query to copied provider session bytes before the view can change.
/// Example: `try self.sendRuntimeChangeReviewQuery(query);`
fn sendRuntimeChangeReviewQuery(self: *AttachedClient, query: core.QueryChangeReview) !void {
    try self.runtime_transport.outbox.pushChangeReviewQuery(query);
    try self.startRuntimeSend();
}

/// Copies comment and path bytes before the originating editor can mutate them.
/// Example: `try self.sendRuntimeChangeReviewCommand(request);`
fn sendRuntimeChangeReviewCommand(self: *AttachedClient, request: core.ChangeReviewCommand) !void {
    try self.runtime_transport.outbox.pushChangeReviewCommand(request);
    try self.startRuntimeSend();
}

/// Registers correlation before copying the request; failed delivery removes only that registration.
/// Example: `try self.sendTabRenameRequest(rename, continuation);`
fn sendTabRenameRequest(self: *AttachedClient, rename: core.RenameTab, continuation: data.RequestsContinuation) !void {
    try self.model.request_lifecycle.tracker.add(rename.request_id, continuation);
    errdefer _ = self.model.request_lifecycle.tracker.take(rename.request_id);
    try self.runtime_transport.outbox.pushRename(rename);
    try self.startRuntimeSend();
}

/// Registers correlation before copying the request; failed delivery removes only that registration.
/// Example: `try self.sendCreateTabRequest(request);`
fn sendCreateTabRequest(self: *AttachedClient, request: core.CreateTab) !void {
    try self.model.request_lifecycle.tracker.add(
        request.request_id,
        .{
            .create_tab = .{
                .workspace = request.workspace,
                .size = request.size,
            },
        },
    );
    errdefer _ = self.model.request_lifecycle.tracker.take(request.request_id);
    try self.runtime_transport.outbox.pushCreateTab(request);
    try self.startRuntimeSend();
}

/// Registers correlation before copying the request; failed delivery removes only that registration.
/// Example: `try self.sendAgentPromptRequest(request, operation);`
fn sendAgentPromptRequest(self: *AttachedClient, request: core.AgentPrompt, operation: data.AgentOperation) !void {
    try self.model.request_lifecycle.tracker.add(
        request.request_id,
        .{
            .agent_prompt = operation,
        },
    );
    errdefer _ = self.model.request_lifecycle.tracker.take(request.request_id);
    try self.runtime_transport.outbox.pushAgentPrompt(request);
    try self.startRuntimeSend();
}

/// Owns a routed response until its asynchronous send completes. Example: `try self.sendRuntimeClientCompletion(reply);`
fn sendRuntimeClientCompletion(self: *AttachedClient, reply: core.ClientCommand) !void {
    try self.runtime_transport.outbox.pushClientCompletion(reply);
    try self.startRuntimeSend();
}

/// Keeps queued data owned by the transport if scheduling fails.
fn startRuntimeSend(self: *AttachedClient) !void {
    const transport = &self.runtime_transport;
    const payload = try transport.prepareSend() orelse return;

    self.workers.start(.{ .runtime_send = .{ .state = transport, .bytes = payload } }) catch |err| {
        transport.cancelSend();

        return err;
    };
}

/// Preserves command correlation and returns either its result or a named failure.
fn completeClientCommand(self: *AttachedClient, command: core.ClientCommand) !void {
    var reply = command;
    self.executeClientCommand(&reply) catch |err| {
        reply.status = .failed;
        try reply.setText(@errorName(err));
    };

    try self.sendRuntimeClientCompletion(reply);
}

/// Validates a routed API request, applies it, and records applied versus admitted status.
fn executeClientCommand(self: *AttachedClient, reply: *core.ClientCommand) !void {
    if (reply.status != .request) {
        return error.InvalidClientCommand;
    }

    switch (reply.action) {
        .plugin_run => {
            try self.runPluginCommand(reply);
        },
        .plugin_disable => {
            try self.setPluginEnabled(reply, false);
        },
        .plugin_enable => {
            try self.setPluginEnabled(reply, true);
        },
        .plugin_get => {
            try self.describePlugin(reply);
        },
        .plugin_list => {
            try self.listPlugins(reply);
        },
        .config_show => {
            try self.showConfiguration(reply);
        },
        .config_reload => {
            try self.requestConfigReload();
            reply.status = .admitted;
        },
        .layout_apply => {
            try self.applyCommandLayout(reply);
        },
        .layout_get => {
            try self.writeCommandLayout(reply);
        },
        .pane_copy => {
            const selection = try core.CopySelection.fromText(@enumFromInt(reply.target_id), reply.text());
            const tab = self.model.tabs.activeSlot() orelse return error.NoActiveTab;
            const pane = self.model.panes.findInConst(self.model.tabs.location[tab].tab_id, selection.pane_id) orelse return error.PaneNotFound;
            if (!pane.attached or pane.kind != .terminal) {
                return error.TerminalPaneNotAttached;
            }

            try self.sendRuntime(
                .{
                    .copy_selection = selection,
                },
            );
            reply.length = 0;
            reply.status = .admitted;
        },
        .pane_scroll => {
            const delta = std.math.cast(i32, reply.value) orelse return error.InvalidScrollDelta;
            const pane_id: core.PaneId = @enumFromInt(reply.target_id);
            const tab = self.model.tabs.activeSlot() orelse return error.NoActiveTab;
            const pane = self.model.panes.findInConst(self.model.tabs.location[tab].tab_id, pane_id) orelse return error.PaneNotFound;
            if (!pane.attached or self.copyModeActive()) {
                return error.PaneViewportUnavailable;
            }

            if (pane.kind == .agent) {
                _ = self.model.scrollAgentThread(pane_id, @floatFromInt(delta));
            } else {
                _ = try self.applyPaneViewport(
                    .{
                        .pane_id = pane_id,
                        .target = .{
                            .relative = delta,
                        },
                    },
                );
            }

            reply.status = .applied;
        },
        .pane_fullscreen => {
            try self.focusCommandPane(reply.target_id);
            const changed = try self.togglePaneFullscreen(
                .{
                    .area = self.geometry().area,
                },
            ) orelse return error.PaneFullscreenUnavailable;
            reply.value = @intFromBool(changed.fullscreen);
            reply.status = .applied;
        },
        .pane_resize => {
            const direction = std.meta.stringToEnum(data.LayoutDirection, reply.text()) orelse return error.InvalidPaneDirection;
            try self.focusCommandPane(reply.target_id);
            if (try self.resizePane(
                .{
                    .direction = direction,
                    .area = self.geometry().area,
                },
            ) == null) {
                return error.PaneResizeUnavailable;
            }

            reply.length = 0;
            reply.status = .applied;
        },
        .pane_focus => {
            try self.focusCommandPane(reply.target_id);
            reply.status = .applied;
        },
        .pane_close => {
            try self.focusCommandPane(reply.target_id);
            if (try self.requestPaneClose() == null) {
                return error.PaneClosureUnavailable;
            }

            reply.status = .admitted;
        },
        .pane_split => {
            const axis = std.meta.stringToEnum(data.LayoutAxis, reply.text()) orelse return error.InvalidSplitAxis;
            try self.focusCommandPane(reply.target_id);
            if (try self.requestPaneSplit(
                .{
                    .axis = axis,
                    .area = self.geometry().area,
                },
            ) == null) {
                return error.PaneCreationUnavailable;
            }

            reply.length = 0;
            reply.status = .admitted;
        },
        .pane_create => {
            if (try self.requestPaneSplit(
                .{
                    .axis = .horizontal,
                    .area = self.geometry().area,
                },
            ) == null) {
                return error.PaneCreationUnavailable;
            }

            reply.status = .admitted;
        },
        .tab_previous => {
            try self.selectCommandTabOffset(reply, -1);
        },
        .tab_next => {
            try self.selectCommandTabOffset(reply, 1);
        },
        .tab_select => {
            const target: core.TabId = @enumFromInt(reply.target_id);
            if (reply.target_id == 0 or self.model.tabLocation(target) == null) {
                return error.TabNotFound;
            }

            if (self.model.activeTabLocation()) |active| {
                if (active.tab_id == target) {
                    reply.status = .applied;
                    return;
                }
            }

            if (try self.selectTab(
                .{
                    .target = .{
                        .tab_id = target,
                    },
                },
            ) == null) {
                return error.ClientBusy;
            }

            reply.status = .admitted;
        },
        .tab_create => {
            if (!try self.requestTabCreation(
                .{
                    .label = reply.text(),
                },
            )) {
                return error.ClientBusy;
            }

            reply.length = 0;
            reply.status = .admitted;
        },
        .workspace_select => {
            if (reply.target_id == 0) {
                return error.InvalidWorkspaceId;
            }

            const target: core.WorkspaceId = @enumFromInt(reply.target_id);
            if (!self.model.knowsWorkspace(target)) {
                return error.WorkspaceNotFound;
            }

            if (self.model.workspace) |location| {
                if (location == .workspace and location.workspace == target) {
                    reply.status = .applied;
                    return;
                }
            }

            if (!try self.selectWorkspace(
                .{
                    .workspace = target,
                },
            )) {
                return error.ClientBusy;
            }

            reply.status = .admitted;
        },
        .client_clipboard_copy => {
            try self.model.to_host.writeClipboard(self.gpa, reply.text());
            reply.length = 0;
            reply.status = .admitted;
        },
        .client_open_link => {
            const target = try data.LinkTarget.init(reply.text());
            if (!try self.openLink(target)) {
                return error.LinkOpeningUnavailable;
            }

            reply.length = 0;
            reply.status = .admitted;
        },
        .notification_dismiss => {
            if (try self.dismissNotificationNow(@enumFromInt(reply.target_id)) == null) {
                return error.NotificationNotFound;
            }

            reply.status = .applied;
        },
        .client_copy_mode => {
            if (!self.copyModeActive() and !self.enterCopyMode()) {
                return error.CopyModeUnavailable;
            }

            reply.status = .applied;
        },
        .client_open_history => {
            if (!try self.beginHistoryPalette()) {
                return error.ClientPromptUnavailable;
            }

            reply.status = .admitted;
        },
        .client_open_goto => {
            if (!self.openNamePrompt(.goto_picker)) {
                return error.ClientPromptUnavailable;
            }

            reply.status = .applied;
        },
        .workspace_list_collapse => {
            _ = self.model.setWorkspaceListCollapsed(true);

            reply.status = .applied;
        },
        .workspace_list_expand => {
            _ = self.model.setWorkspaceListCollapsed(false);

            reply.status = .applied;
        },
        .sidebar_resize => {
            const width = std.math.cast(u16, reply.value) orelse return error.InvalidWidth;
            if (width == 0) {
                return error.InvalidWidth;
            }

            _ = try self.resizeSidebar(
                .{
                    .exact = width,
                },
            );
            try self.writeCommandSidebarState(reply);
        },
        .sidebar_hide => {
            if (self.model.sidebar_visible) {
                _ = try self.toggleSidebar();
            }

            try self.writeCommandSidebarState(reply);
        },
        .sidebar_show => {
            if (!self.model.sidebar_visible) {
                _ = try self.toggleSidebar();
            }

            try self.writeCommandSidebarState(reply);
        },
        .sidebar_get => {
            try self.writeCommandSidebarState(reply);
        },
        .agent_view_expand, .agent_view_collapse => {
            _ = self.model.agentPane(@enumFromInt(reply.target_id)) orelse return error.AgentPaneNotAttached;
            const item_id = std.fmt.parseUnsigned(
                u64,
                reply.text(),
                10,
            ) catch return error.InvalidItemId;
            if (item_id == 0 or (reply.value != 0 and reply.value != 1)) {
                return error.InvalidThreadControl;
            }

            try self.host_input_source.setThreadExpansion(
                .{
                    .pane_id = @enumFromInt(reply.target_id),
                    .item_id = item_id,
                    .expanded = reply.action == .agent_view_expand,
                    .work = reply.value == 1,
                },
            );
            reply.length = 0;
            reply.status = .applied;
        },
        .agent_draft_attach => {
            const pane_id: core.PaneId = @enumFromInt(reply.target_id);
            const pane = self.model.agentPane(pane_id) orelse return error.AgentPaneNotAttached;

            if (!try self.model.attachAgentImage(pane_id, reply.text())) {
                return error.DraftAttachmentRejected;
            }

            reply.value = pane.composerImages().count;
            reply.length = 0;
            reply.status = .applied;
        },
        .agent_draft_set => {
            const pane_id: core.PaneId = @enumFromInt(reply.target_id);
            const pane = self.model.agentPane(pane_id) orelse return error.AgentPaneNotAttached;
            if (std.mem.indexOfScalar(
                u8,
                reply.text(),
                0,
            ) != null) {
                return error.InvalidDraftText;
            }

            if (!std.mem.eql(
                u8,
                pane.composerSlice(),
                reply.text(),
            )) {
                if (!self.model.editAgentComposer(
                    pane_id,
                    .{
                        .replace_range = .{
                            .range = .{
                                0,
                                @intCast(pane.composerSlice().len),
                            },
                            .text = reply.text(),
                        },
                    },
                )) {
                    return error.DraftEditRejected;
                }
            }

            reply.length = 0;
            reply.status = .applied;
        },
        .agent_draft_get => {
            const pane_id: core.PaneId = @enumFromInt(reply.target_id);
            const pane = self.model.agentPane(pane_id) orelse return error.AgentPaneNotAttached;
            reply.value = pane.composerImages().count;
            try reply.setText(pane.composerSlice());
            reply.status = .applied;
        },
        .agent_create => {
            if (!self.model.host.host_capabilities.agent_panes) {
                return error.AgentPanesUnsupported;
            }

            if (!try self.requestTabCreation(
                .{
                    .kind = .agent,
                    .label = if (reply.length == 0) "Codex" else reply.text(),
                },
            )) {
                return error.ClientBusy;
            }

            reply.length = 0;
            reply.status = .admitted;
        },
    }
}

/// Resolves an explicit API target before any focus-dependent operation.
fn focusCommandPane(self: *AttachedClient, target_id: u64) !void {
    if (target_id == 0) {
        return error.InvalidPaneId;
    }

    const pane_id: core.PaneId = @enumFromInt(target_id);
    const tab = self.model.tabs.activeSlot() orelse return error.NoActiveTab;
    _ = self.model.panes.findInConst(self.model.tabs.location[tab].tab_id, pane_id) orelse return error.PaneNotFound;
    if (self.model.tabs.layout[tab].focused() == pane_id) {
        return;
    }

    if (!((try self.applyPaneFocus(
        .{
            .target = .{
                .pane_id = pane_id,
            },
            .area = self.geometry().area,
        },
    )) != null)) {
        return error.PaneFocusUnavailable;
    }
}

fn selectCommandTabOffset(self: *AttachedClient, reply: *core.ClientCommand, offset: isize) !void {
    if (self.model.activeTabLocation() == null) {
        return error.NoActiveTab;
    }

    if (self.model.request_lifecycle.tracker.has(.tab_snapshot)) {
        return error.ClientBusy;
    }

    const change = try self.selectTab(
        .{
            .target = .{
                .offset = offset,
            },
        },
    );
    reply.status = if (change == null) .applied else .admitted;
}

fn writeCommandSidebarState(self: *const AttachedClient, reply: *core.ClientCommand) !void {
    reply.value = self.model.sidebar_width;
    try reply.setText(if (self.model.sidebar_visible) "visible" else "hidden");
    reply.status = .applied;
}

/// Encodes the active layout with stable pane identities into the bounded reply.
fn writeCommandLayout(self: *const AttachedClient, reply: *core.ClientCommand) !void {
    const tab = self.model.tabs.activeSlot() orelse return error.NoActiveTab;
    const focused = self.model.tabs.layout[tab].focused() orelse return error.NoFocusedPane;
    var nodes: [core.max_client_layout_nodes]core.ClientLayoutNode = undefined;
    const tabs = [_]core.ClientTabLayout{
        .{
            .location = self.model.tabs.location[tab],
            .focused_pane = focused,
            .fullscreen = self.model.tabs.layout[tab].isFullscreen(),
            .workspace_active = true,
            .nodes = self.model.tabs.layout[tab].clientLayoutNodes(&nodes),
        },
    };

    var buffer: [core.ClientCommand.capacity / 2]u8 = undefined;
    const encoded = try core.encodeClientLayoutSnapshot(
        &buffer,
        .{
            .restored = true,
            .sidebar_visible = self.model.sidebar_visible,
            .sidebar_width = self.model.sidebar_width,
            .workspace_list_collapsed = self.model.workspace_list_collapsed,
            .active_tab = self.model.tabs.location[tab],
            .tabs = &tabs,
        },
    );
    const text = try std.fmt.bufPrint(
        &reply.bytes,
        "{x}",
        .{
            encoded,
        },
    );
    reply.length = @intCast(text.len);
    reply.status = .applied;
}

/// Validates the owned layout token before committing geometry.
fn applyCommandLayout(self: *AttachedClient, reply: *core.ClientCommand) !void {
    if (!self.model.request_lifecycle.tracker.isEmpty()) {
        return error.ClientBusy;
    }

    var bytes: [core.ClientCommand.capacity / 2]u8 = undefined;
    const encoded = try std.fmt.hexToBytes(&bytes, reply.text());
    const message = try core.decodeServer(encoded);
    if (message != .client_layout_snapshot) {
        return error.InvalidLayoutToken;
    }

    const snapshot = message.client_layout_snapshot;
    if (!snapshot.restored or snapshot.tab_count != 1 or snapshot.active_tab == null) {
        return error.InvalidLayoutToken;
    }

    var tabs = snapshot.tabs();
    const tab = (try tabs.next()) orelse return error.InvalidLayoutToken;
    if (!std.meta.eql(tab.location, snapshot.active_tab.?)) {
        return error.InvalidLayoutToken;
    }

    var ids: [core.max_panes_per_tab]core.PaneId = undefined;
    var count: usize = 0;
    var nodes = tab.nodes();
    while (try nodes.next()) |node| {
        if (node == .pane) {
            if (count == ids.len) {
                return error.InvalidLayoutToken;
            }

            ids[count] = node.pane.id;
            count += 1;
        }
    }

    try self.applyPaneLayout(
        .{
            .location = tab.location,
            .layout = try data.WorkspaceLayout.fromClientLayout(tab),
            .panes = .{
                .ids = ids[0..count],
                .focused = tab.focused_pane,
            },
            .area = self.geometry().area,
        },
    );
    reply.length = 0;
    reply.status = .applied;
}

fn navigatePane(self: *AttachedClient, direction: data.InputDirection) !void {
    const key = navigationKey(direction);
    if (std.mem.eql(
        u8,
        self.model.focusedPaneForeground(),
        "nvim",
    )) {
        _ = try self.sendPaneInput(
            .{
                .target = .focused,
                .source = .host,
                .payload = .{
                    .key = key,
                },
            },
        );
        return;
    }

    _ = try self.applyPaneFocus(
        .{
            .target = .{
                .direction = switch (direction) {
                    .left => .left,
                    .right => .right,
                    .up => .up,
                    .down => .down,
                },
            },
            .area = self.geometry().area,
        },
    );
}

fn navigationKey(direction: data.InputDirection) data.Key {
    return switch (direction) {
        .left => ctrl_h,
        .right => ctrl_l,
        .up => ctrl_k,
        .down => ctrl_j,
    };
}

fn scrollPane(self: *AttachedClient, direction: data.ScrollDirection) !void {
    const model = self.model.tabs.activeSlot() orelse return;

    _ = try self.inputPaneMouse(
        model,
        .{
            .focused_scroll = direction,
        },
    );
}

fn createCommandTab(self: *AttachedClient, command: *const data.CommandTab) !void {
    var arguments: [data.CommandTab.max_arguments][]const u8 = undefined;
    for (0..command.argument_count) |index| {
        arguments[index] = command.argument(index);
    }

    _ = try self.requestTabCreation(
        .{
            .label = command.label(),
            .arguments = arguments[0..command.argument_count],
        },
    );
}

fn executeLuaAction(self: *AttachedClient, command: data.LuaActionCommand) !data.KeybindControl {
    const copy_mode_active = self.copyModeActive();
    const outcome = try self.evaluateLuaAction(command);
    switch (outcome) {
        .applied, .unavailable, .invocation_failed, .validation_failed => return .continue_routing,
        .exit => return .stop,
        .input => |decision| switch (decision) {
            .consume => {},
            .forward_binding, .keys => |keys| for (keys.slice()) |key| {
                _ = try self.routeKeyInput(
                    .{
                        .key = key,
                    },
                );
            },
            .paste => |paste| {
                if (!copy_mode_active) {
                    _ = try self.pasteExpression(paste.slice());
                }
            },
        },
    }

    return .continue_routing;
}

/// Rejects obsolete geometry before invalidating placements and resizing attachments.
fn deliverPaneGeometry(self: *AttachedClient, change: data.PaneGeometryChange) !void {
    const active = self.model.tabs.activeSlot() orelse return error.StalePaneGeometry;
    if (!std.meta.eql(self.model.tabs.location[active], change.location) or
        self.model.tabs.layout[active].focused() != change.focused or
        self.model.tabs.layout[active].isFullscreen() != change.fullscreen or
        self.model.version().panes != change.panes_revision)
    {
        return error.StalePaneGeometry;
    }

    self.model.to_host.invalidate_placements = true;
    try self.resizeAttachedPanes(active, change.area);

    if (self.model.tabs.snapshot_loaded[active]) {
        try self.attachVisiblePanes(active, change.area);
    }
}

/// A failed attachment repairs membership only while that pane is still detached.
fn recoverPaneAttachment(self: *AttachedClient, attachment: data.PaneAttachment) !bool {
    if (!self.model.needsPaneAttachment(attachment)) {
        return false;
    }

    _ = try self.recoverTabSnapshot(attachment.location);
    return true;
}

fn sendPaneSplitRequest(self: *AttachedClient, plan: data.PaneSplitPlan) !void {
    const request_id = try self.model.request_lifecycle.nextId();
    try self.sendRuntimeRequest(
        .{
            .registration = .{
                .request_id = request_id,
                .continuation = .{
                    .split = .{
                        .target_pane = plan.split.target_pane,
                        .location = plan.split.location,
                        .axis = plan.split.axis,
                        .area = plan.split.area,
                    },
                },
            },
            .message = .{
                .create_pane = .{
                    .request_id = request_id,
                    .location = plan.split.location,
                    .size = plan.new_pane_size,
                    .launch = .{
                        .cwd = self.options.cwd,
                        .cwd_source = plan.split.target_pane,
                        .arguments = if (plan.arguments.len != 0) plan.arguments else self.options.arguments,
                    },
                },
            },
        },
    );
}

/// Adopts only the exact runtime reply. Apply effects immediately after the
/// commit, without exposing a second API that accepts potentially stale commits.
/// Runtime correlation supplies the exact pending split before committing it.
fn confirmPaneSplit(self: *AttachedClient, command: data.ConfirmPaneSplit) !data.PaneSplitCommit {
    if (!command.created or command.confirmed_pane == command.requested.target_pane or
        !std.meta.eql(command.confirmed_location, command.requested.location))
    {
        return error.UnexpectedPane;
    }

    const commit = try self.model.commitPaneSplit(
        .{
            .split = command.requested,
            .new_pane = command.confirmed_pane,
        },
    );
    switch (commit.disposition) {
        .active => {
            const tab = self.model.tabs.find(commit.location.tab_id).?;
            try self.resizeAttachedPanes(tab, commit.area);
            try self.synchronizeActivePane();
        },
        .inactive => {
            try self.sendRuntime(
                .{
                    .detach_pane = .{
                        .pane_id = commit.pane_id,
                    },
                },
            );
            try self.graphics.setPaneVisible(commit.pane_id, false);
        },
        .stale => {
            // A late reply may reference an identity now represented elsewhere.
            // Never detach a pane belonging to the current workspace view.
            if (self.model.panes.find(commit.pane_id) != null) {
                return error.StalePaneSplitConfirmation;
            }

            try self.sendRuntime(
                .{
                    .detach_pane = .{
                        .pane_id = commit.pane_id,
                    },
                },
            );
            if (self.model.workspace) |workspace| {
                if (std.meta.eql(workspace, commit.location.workspace) and !self.model.request_lifecycle.tracker.has(.workspace_snapshot)) {
                    try self.requestWorkspaceSnapshot(workspace);
                }
            }
        },
    }

    return commit;
}

/// Restores only the still-active requested target. A retired target is stale;
/// a target in an inactive tab is already detached and needs no resize.
/// A rejected request restores the active target before the failure notice.
fn recoverPaneSplit(self: *AttachedClient, split: data.PaneSplit) !SplitRecovery {
    return switch (self.model.recoverPaneSplit(
        .{
            .split = split,
            .area = self.geometry().area,
        },
    )) {
        .resize => |resize| recovery: {
            try self.sendRuntime(
                .{
                    .pane_resize = resize,
                },
            );
            break :recovery .restored;
        },
        .not_required => .not_required,
        .stale => .stale,
    };
}

/// Consumes the request once before applying its confirmation and agent attachment.
fn completePaneOpen(self: *AttachedClient, opened: core.PaneOpened) !PaneOpenOutcome {
    const continuation = self.model.request_lifecycle.tracker.take(opened.request_id) orelse
        return error.UnexpectedRequest;
    const outcome: PaneOpenOutcome = switch (continuation) {
        .initial_open => result: {
            try self.arriveOpenedWorkspace(translateOpenedPane(opened));
            break :result .workspace_arrived;
        },
        .create_workspace => |size| result: {
            try self.createOpenedWorkspace(
                .{
                    .opened = translateOpenedPane(opened),
                    .requested_size = size,
                },
            );
            break :result .workspace_created;
        },
        .split => |split| result: {
            _ = try self.confirmPaneSplit(
                .{
                    .requested = .{
                        .target_pane = split.target_pane,
                        .location = split.location,
                        .axis = split.axis,
                        .area = split.area,
                    },
                    .confirmed_pane = opened.pane_id,
                    .confirmed_location = opened.location,
                    .created = opened.created,
                },
            );
            break :result .pane_split;
        },
        .attach_pane => |attachment| result: {
            try self.confirmPaneAttachment(
                .{
                    .requested = .{
                        .pane_id = attachment.pane_id,
                        .location = attachment.location,
                    },
                    .opened = translateOpenedPane(opened),
                },
            );
            break :result .pane_attached;
        },
        .ignored => .ignored,
        else => return error.UnexpectedRequest,
    };

    if (outcome != .ignored) {
        try self.identifyOpenedPane(opened);
    }

    return outcome;
}

fn translateOpenedPane(opened: core.PaneOpened) data.OpenedPane {
    return .{
        .pane_id = opened.pane_id,
        .location = opened.location,
        .created = opened.created,
    };
}

fn arriveOpenedWorkspace(self: *AttachedClient, opened: data.OpenedPane) !void {
    const size = data.multiplexer.rectSize(self.geometry().area) orelse return error.TerminalTooSmall;
    const activation = try self.model.arriveWorkspace(workspaceArrival(
        &self.model.navigation_history,
        opened,
        size,
    ));
    try self.activateWorkspace(activation);
}

fn createOpenedWorkspace(self: *AttachedClient, confirmation: data.WorkspaceCreation) !void {
    if (!confirmation.opened.created) {
        return error.UnexpectedRequest;
    }

    const replacement = try self.model.replaceWorkspace(workspaceArrival(
        &self.model.navigation_history,
        confirmation.opened,
        confirmation.requested_size,
    ));
    self.releaseWorkspace(&replacement.departure);
    try self.activateWorkspace(replacement.activation);
}

/// Rejects mismatched or newly created panes before committing an attachment.
fn confirmPaneAttachment(self: *AttachedClient, confirmation: data.PaneAttachmentConfirmation) !void {
    const confirmed: data.PaneAttachment = .{
        .pane_id = confirmation.opened.pane_id,
        .location = confirmation.opened.location,
    };

    if (confirmation.opened.created or !std.meta.eql(confirmation.requested, confirmed)) {
        return error.UnexpectedPane;
    }

    _ = try self.model.confirmPaneAttachment(confirmed);
}

/// Recovers the correlated operation before publishing its failure notification.
fn failRuntimeRequest(self: *AttachedClient, failure: core.RequestFailed) !data.RequestFailureOutcome {
    const continuation = self.model.request_lifecycle.tracker.take(failure.request_id) orelse {
        reportRuntimeFailure(failure.message);

        return error.UnexpectedRequestFailure;
    };

    if (continuation == .ignored) {
        self.retireChangeReview(failure.request_id);
        agent_reading.retired(&self.model);
    }

    if (continuation == .agent_history) {
        defer agent_reading.retired(
            &self.model,
        );
        if (!agent_reading.failed(
            &self.model,
            continuation.agent_history,
            failure.message,
        )) {
            return .ignored;
        }
    }

    switch (continuation) {
        .change_review_query, .change_review_command => |operation| {
            if (!self.failChangeReview(operation, failure.message)) {
                return .ignored;
            }
        },
        else => {},
    }

    _ = self.model.editor_open.complete(failure.request_id);

    errdefer reportRuntimeFailure(failure.message);
    switch (continuation) {
        .ignored => return .ignored,
        .workspace_snapshot, .tab_snapshot => return error.RuntimeRequestFailed,
        .initial_open => |open| {
            const outcome = try self.recoverWorkspaceSwitch(open.fallback_workspace, failure.code);
            return switch (outcome) {
                .retried => .recovered,
                .unrecoverable => error.RuntimeRequestFailed,
            };
        },
        .split => |split| {
            const outcome = try self.recoverPaneSplit(
                .{
                    .target_pane = split.target_pane,
                    .location = split.location,
                    .axis = split.axis,
                    .area = split.area,
                },
            );
            if (outcome == .stale) {
                return .ignored;
            }
        },
        .attach_pane => |attachment| {
            if (failure.code == .pane_not_found) {
                _ = try self.recoverPaneAttachment(
                    .{
                        .pane_id = attachment.pane_id,
                        .location = attachment.location,
                    },
                );
            }
        },
        .close_tab => |location| {
            _ = try self.recoverTabClose(location);
        },
        .close_pane,
        .create_workspace,
        .rename_workspace,
        .create_tab,
        .rename_tab,
        .move_tab,
        .notification,
        .agent_prompt,
        .agent_control,
        .agent_query,
        .agent_history,
        .change_review_query,
        .change_review_command,
        .editor_open,
        => {},
    }

    try self.publishNotificationNow(data.request_failure.notification(
        .{
            .continuation = continuation,
            .code = failure.code,
            .message = failure.message,
        },
    ));
    return .notified;
}

fn reportRuntimeFailure(message: []const u8) void {
    if (builtin.is_test) {
        return;
    }

    std.debug.print(
        "telar runtime: {s}\n",
        .{
            message,
        },
    );
}

/// Transfers only credits admitted by the outbox; saturation preserves the rest.
fn queueGraphicsCredits(self: *AttachedClient) void {
    while (self.graphics.peekCredit()) |credit| {
        self.runtime_transport.outbox.push(
            .{
                .graphics_credit = .{
                    .pane_id = credit.pane_id,
                    .bytes = @intCast(credit.bytes),
                },
            },
        ) catch break;
        self.graphics.consumeCredit(credit);
    }
}

/// Delivers a current commit, stopping at the first failed resource operation.
fn deliverHostCommit(self: *AttachedClient, commit: data.HostCommit) !void {
    try validateHostCommit(&self.model, commit);

    if (commit.capabilities) |change| {
        if (!std.meta.eql(change.previous.terminal_colors, change.current.terminal_colors) and
            (self.model.startup.phase == .opening or self.model.startup.phase == .active))
        {
            try self.sendRuntime(
                .{
                    .configure_terminal_colors = change.current.terminal_colors,
                },
            );
        }

        if (change.previous.appearance != change.current.appearance and !self.options.theme_locked) {
            const theme = switch (change.current.appearance) {
                .unknown => null,
                .light => self.model.config.themes.light,
                .dark => self.model.config.themes.dark,
            };

            if (theme) |value| {
                self.model.theme = value;
            }
        }

        if (change.previous.images != change.current.images) {
            pane_graphics.syncFallbacks(&self.model, self.graphics);
            self.model.to_host.invalidate_placements = true;
        }
    }

    if (commit.resize) |_| {
        self.model.to_host.invalidate_placements = true;
        if (self.model.tabs.activeSlot()) |tab| {
            const area = self.geometry().area;
            try self.resizeAttachedPanes(tab, area);

            if (self.model.tabs.snapshot_loaded[tab]) {
                try self.attachVisiblePanes(tab, area);
            }
        }
    }
}

fn validateHostCommit(model: *const data.ClientModel, commit: data.HostCommit) !void {
    if (commit.capabilities == null and commit.resize == null) {
        return error.EmptyHostCommit;
    }

    const version = model.version();

    if (commit.capabilities) |change| {
        if (!std.meta.eql(model.host.host_capabilities, change.current) or
            version.host_capabilities != change.host_capabilities_revision)
        {
            return error.StaleHostCommit;
        }
    }

    if (commit.resize) |resize| {
        if (!std.meta.eql(model.host.host_size, resize.current) or version.host != resize.host_revision) {
            return error.StaleHostCommit;
        }
    }
}

/// Copies borrowed wire content before the next receive can overwrite it.
fn applyChangeReview(self: *AttachedClient, response: core.ChangeReviewSnapshotView) !bool {
    const continuation = self.model.request_lifecycle.tracker.take(response.request_id) orelse return false;
    const owner: data.ChangeReviewOperation = switch (continuation) {
        .change_review_query, .change_review_command => |owner| owner,
        .ignored => {
            self.retireChangeReview(response.request_id);
            return false;
        },
        else => return error.UnexpectedControlReply,
    };

    const accepted = self.applyChangeReviewResponse(owner, response) catch |err| {
        _ = self.failChangeReview(owner, @errorName(err));
        return false;
    };

    return accepted;
}

/// Retires a correlated reply after pane or tab removal without leaving a busy view.
fn retireChangeReview(self: *AttachedClient, request_id: core.RequestId) void {
    if (self.model.change_review.pending != request_id) {
        return;
    }

    const owner = self.model.change_review.owner orelse return;
    _ = self.failChangeReview(owner, "The pane was detached; reopen its review");
}

/// Opens any attached pane, including an agent launched in an ordinary terminal.
fn openChangeReviewSession(self: *AttachedClient, pane_id: core.PaneId) !void {
    const pane = findReviewPane(&self.model, pane_id) orelse return error.ChangeReviewPaneUnavailable;
    self.model.change_review.open(
        .{
            .pane_id = pane.id,
            .pane_generation = pane.pane_generation,
            .attachment_generation = pane.attachment_generation,
            .location = pane.location,
            .view_generation = 0,
            .edition_id = 0,
        },
    );
    self.model.chrome_revision +%= 1;
}

/// Captures the attached owner for a bounded, correlated request.
fn changeReviewOperation(self: *AttachedClient, edition_id: u64) !data.ChangeReviewOperation {
    if (self.model.change_review.session_changed) {
        return error.RetiredChangeReviewSession;
    }

    if (self.model.change_review.pending != null) {
        return error.ChangeReviewRequestPending;
    }

    var owner = self.model.change_review.owner orelse return error.ChangeReviewClosed;
    if (resolveReviewPane(&self.model, owner) == null) {
        return error.ChangeReviewPaneUnavailable;
    }

    owner.edition_id = edition_id;
    if (self.model.change_review.loaded) {
        try owner.setSession(self.model.change_review.snapshot.session);
    }

    return owner;
}

fn beginChangeReview(self: *AttachedClient, request_id: core.RequestId) void {
    self.model.change_review.begin(request_id);
    self.model.chrome_revision +%= 1;
}

/// Applies a reply only while both the attachment and view still exist.
fn applyChangeReviewResponse(self: *AttachedClient, owner: data.ChangeReviewOperation, response: core.ChangeReviewSnapshotView) !bool {
    if (resolveReviewPane(&self.model, owner) == null) {
        _ = self.failChangeReview(owner, "The pane was detached; reopen its review");
        return false;
    }

    const applied = try self.model.change_review.apply(owner, response);
    if (applied) {
        self.model.chrome_revision +%= 1;
    }

    return applied;
}

/// Retains pane availability even when its review is closed, and refreshes an open view.
fn changeReviewChanged(self: *AttachedClient, notification: core.ChangeReviewChanged) bool {
    const pane = findReviewPane(&self.model, notification.pane_id) orelse return false;
    const availability_changed = pane.applyChangeReview(notification);
    const review_changed = if (self.model.change_review.owner) |owner| resolveReviewPane(&self.model, owner) != null and self.model.change_review.changed(notification) else false;
    if (!availability_changed and !review_changed) {
        return false;
    }

    self.model.chrome_revision +%= 1;
    return true;
}

/// Retains review content and exposes failure without clearing adapter drafts.
fn failChangeReview(self: *AttachedClient, owner: data.ChangeReviewOperation, message: []const u8) bool {
    if (!self.model.change_review.failed(owner, message)) {
        return false;
    }

    self.model.chrome_revision +%= 1;
    return true;
}

fn reportChangeReview(self: *AttachedClient, message: []const u8) void {
    self.model.change_review.report(message);
    self.model.chrome_revision +%= 1;
}

fn findReviewPane(model: *data.ClientModel, pane_id: core.PaneId) ?*data.Pane {
    const pane = model.panes.find(pane_id) orelse return null;
    return if (pane.attached and pane.pane_generation != 0) pane else null;
}

fn resolveReviewPane(model: *data.ClientModel, owner: data.ChangeReviewOperation) ?*const data.Pane {
    const pane = findReviewPane(model, owner.pane_id) orelse return null;
    return if (pane.pane_generation == owner.pane_generation and pane.attachment_generation == owner.attachment_generation) pane else null;
}

fn linkTargetAt(model: *data.ClientModel, tab: usize, event: data.Mouse, area: core.Rect) ?data.LinkTarget {
    const plan = data.tab_layout.planPaneMouse(model, tab, event, area) orelse return null;
    const pane = model.panes.findInConst(model.tabs.location[tab].tab_id, plan.pane_id) orelse return null;

    return data.cells.extract(
        &pane.buffer,
        pane.scroll,
        .{
            .x = event.x - plan.content.x,
            .y = pane.scroll.offset + event.y - plan.content.y,
        },
    );
}

fn openLinkFile(self: *AttachedClient, path: data.FilePath) !void {
    const editor = self.editorExecutable();
    if (editor.len == 0) {
        return error.EditorUnavailable;
    }

    _ = try self.requestTabCreation(
        .{
            .arguments = &.{
                editor,
                path.slice(),
            },
        },
    );
}

fn openExternalLink(self: *AttachedClient, target: data.LinkTarget) !void {
    switch (self.model.link_opening.request(target)) {
        .queued => {},
        .start => |selected| self.workers.start(.{ .link = selected }) catch |err| {
            self.model.link_opening.schedulingFailed();

            return err;
        },
    }
}

fn reportLinkFailure(self: *AttachedClient, err: anyerror) !void {
    try self.publishNotificationNow(
        .{
            .level = .warning,
            .title = "Could not open link",
            .message = @errorName(err),
        },
    );
}

fn openEditorPane(self: *AttachedClient, pane_id: core.PaneId, path: data.FilePath) !void {
    const editor = self.editorExecutable();
    if (editor.len == 0) {
        return error.EditorUnavailable;
    }

    const model = self.model.tabs.activeSlot() orelse return error.PaneNotFound;
    const source = self.model.panes.findInConst(self.model.tabs.location[model].tab_id, pane_id) orelse return error.PaneNotFound;
    var request: core.OwnedEditorOpen = .{
        .request_id = .none,
        .pane_id = pane_id,
        .pane_generation = source.pane_generation,
    };

    try request.setTarget(editor, path.slice());
    const kind = core.editor.identify(editor);
    var reusable = false;
    if (kind != .unsupported and source.pane_generation != 0) {
        var panes = self.model.panes.iterateConst(self.model.tabs.location[model].tab_id);
        while (panes.next()) |pane| {
            reusable = reusable or core.editor.identify(pane.foregroundName()) == kind;
        }
    }

    if (!reusable) {
        return self.splitEditorPane(request);
    }

    request.request_id = try self.model.request_lifecycle.nextId();
    try self.model.editor_open.begin(request);
    errdefer _ = self.model.editor_open.complete(request.request_id);
    try self.sendRuntimeRequest(
        .{
            .registration = .{
                .request_id = request.request_id,
                .continuation = .{
                    .editor_open = .{
                        .pane_id = pane_id,
                        .pane_generation = source.pane_generation,
                        .attachment_generation = source.attachment_generation,
                        .location = source.location,
                    },
                },
            },
            .message = .{
                .open_editor = request.view(),
            },
        },
    );
}

/// Applies a correlated reply only while the originating view still exists.
fn completeEditorOpen(self: *AttachedClient, reply: core.EditorOpened) !void {
    const request = self.model.editor_open.complete(reply.request_id) orelse return;
    const continuation = self.model.request_lifecycle.tracker.take(reply.request_id) orelse return;
    if (continuation != .editor_open) {
        return;
    }

    const operation = continuation.editor_open;
    const model = self.model.tabs.activeSlot() orelse return;
    const source = self.model.panes.findInConst(self.model.tabs.location[model].tab_id, operation.pane_id) orelse return;
    if (source.pane_generation != operation.pane_generation or source.attachment_generation != operation.attachment_generation or !std.meta.eql(source.location, operation.location)) {
        return;
    }

    switch (reply.outcome) {
        .unavailable => self.splitEditorPane(request) catch |err| try self.reportLinkFailure(err),
        .failed => try self.reportLinkFailure(error.EditorOpenFailed),
        .opened => {
            const pane = self.model.panes.findInConst(self.model.tabs.location[model].tab_id, reply.pane_id) orelse return;
            if (pane.pane_generation != reply.pane_generation) {
                return;
            }

            _ = try self.applyPaneFocus(
                .{
                    .target = .{
                        .pane_id = reply.pane_id,
                    },
                    .area = self.geometry().area,
                },
            );
        },
    }
}

fn splitEditorPane(self: *AttachedClient, request: core.OwnedEditorOpen) !void {
    const plan = try self.requestPaneSplit(
        .{
            .axis = .horizontal,
            .area = self.geometry().area,
            .target_pane = request.pane_id,
            .arguments = &.{
                request.editor(),
                request.path(),
            },
        },
    );
    if (plan == null) {
        return error.PaneSplitUnavailable;
    }
}

/// Consumes a page response once, before receive storage can be reused.
fn applyAgentHistory(self: *AttachedClient, response: core.AgentHistoryPageView) !bool {
    const continuation = self.model.request_lifecycle.tracker.take(response.request_id) orelse return false;

    defer agent_reading.retired(&self.model);
    if (continuation == .ignored) {
        return false;
    }

    if (continuation != .agent_history) {
        return error.UnexpectedControlReply;
    }

    return agent_reading.apply(
        &self.model,
        continuation.agent_history,
        response,
    ) catch |err| {
        _ = agent_reading.failed(
            &self.model,
            continuation.agent_history,
            @errorName(err),
        );
        try self.reportAgentHistoryFailure(@errorName(err));
        return false;
    };
}

fn reportAgentHistoryFailure(self: *AttachedClient, message: []const u8) !void {
    try self.publishNotificationNow(
        .{
            .level = .failure,
            .title = "Could not load messages",
            .message = message,
        },
    );
}

fn createAgentTab(self: *AttachedClient) !void {
    if (!self.model.host.host_capabilities.agent_panes) {
        try self.publishNotificationNow(
            .{
                .level = .info,
                .title = "Agent panes require the GUI",
                .message = "Open Telar GUI to create an agent tab.",
            },
        );
        return;
    }

    _ = try self.requestTabCreation(
        .{
            .kind = .agent,
            .label = "Codex",
        },
    );
}

fn queryAgentThread(self: *AttachedClient, pane_id: core.PaneId) !void {
    const pending = agentOperation(&self.model, pane_id) orelse return;
    if (self.model.request_lifecycle.tracker.hasPane(.agent_query, pane_id)) {
        return;
    }

    const request_id = try self.model.request_lifecycle.nextId();
    try self.sendRuntimeRequest(
        .{
            .registration = .{
                .request_id = request_id,
                .continuation = .{
                    .agent_query = pending,
                },
            },
            .message = .{
                .query_agent_thread = .{
                    .request_id = request_id,
                    .pane_id = pane_id,
                    .pane_generation = pending.pane_generation,
                },
            },
        },
    );
}

fn completeAgentRequest(self: *AttachedClient, reply: core.RequestCompleted) !void {
    const continuation = self.model.request_lifecycle.tracker.take(reply.request_id) orelse return error.UnexpectedControlReply;
    switch (continuation) {
        .agent_prompt => |pending| {
            _ = self.model.completeAgentPrompt(pending);
        },
        .agent_control, .agent_query, .ignored => {},
        else => return error.UnexpectedControlReply,
    }
}

/// Sets runtime pane identity after the existing attachment flow commits.
fn identifyOpenedPane(self: *AttachedClient, opened_pane: core.PaneOpened) !void {
    if (self.model.identifyPane(opened_pane) and opened_pane.kind == .agent) {
        try self.queryAgentThread(opened_pane.pane_id);
    }
}

fn agentOperation(model: *const data.ClientModel, pane_id: core.PaneId) ?data.AgentOperation {
    const pane = model.agentPane(pane_id) orelse return null;
    return .{
        .pane_id = pane_id,
        .pane_generation = pane.pane_generation,
        .attachment_generation = pane.attachment_generation,
        .location = pane.location,
    };
}

fn applyTabSnapshot(self: *AttachedClient, snapshot: core.TabSnapshotView) !TabSnapshotOutcome {
    const continuation = self.model.request_lifecycle.tracker.take(snapshot.request_id) orelse
        return error.UnexpectedTabSnapshot;
    const expected_location = switch (continuation) {
        .tab_snapshot => |location| location,
        .ignored => return .ignored,
        else => return error.UnexpectedTabSnapshot,
    };

    if (!std.meta.eql(expected_location, snapshot.location)) {
        return error.UnexpectedTabSnapshot;
    }

    var pane_ids: [core.max_panes_per_tab]core.PaneId = undefined;
    var pane_count: usize = 0;
    var panes = snapshot.panes();
    while (try panes.next()) |pane| {
        if (pane_count == pane_ids.len) {
            return error.TooManyPanes;
        }

        pane_ids[pane_count] = pane.pane_id;
        pane_count += 1;
    }

    const reconciliation = try self.model.reconcileTab(
        .{
            .location = snapshot.location,
            .panes = pane_ids[0..pane_count],
        },
        self.geometry().area,
    );

    for (reconciliation.removed_panes.slice()) |pane_id| {
        self.model.request_lifecycle.tracker.ignorePane(pane_id);
        self.releasePaneResources(pane_id);
    }

    if (reconciliation.active) {
        const tab = self.model.tabs.find(reconciliation.location.tab_id) orelse return error.StaleTabReconciliation;
        try self.synchronizeActivePane();
        try self.resizeAttachedPanes(tab, reconciliation.area);
        try self.attachVisiblePanes(tab, reconciliation.area);
    }

    return .applied;
}

fn applyWorkspaceSnapshot(self: *AttachedClient, snapshot: core.WorkspaceSnapshotView) !void {
    const continuation = self.model.request_lifecycle.tracker.take(snapshot.request_id) orelse
        return error.UnexpectedWorkspaceSnapshot;
    const expected_workspace = switch (continuation) {
        .workspace_snapshot => |workspace| workspace,
        .rename_workspace => |workspace| workspace,
        else => return error.UnexpectedWorkspaceSnapshot,
    };

    if (!std.meta.eql(expected_workspace, snapshot.workspace)) {
        return error.UnexpectedWorkspaceSnapshot;
    }

    var tabs: [core.max_tabs_per_workspace]data.WorkspaceTabInput = undefined;
    var foregrounds: [core.max_tabs_per_workspace][core.max_panes_per_tab]core.PaneForeground = undefined;
    var tab_count: usize = 0;
    var iterator = snapshot.tabs();
    while (try iterator.next()) |tab| {
        if (tab_count == tabs.len) {
            return error.TooManyTabs;
        }

        var names = tab.foregrounds();
        var name_count: usize = 0;
        while (try names.next()) |foreground| {
            if (name_count == core.max_panes_per_tab) {
                return error.TooManyPanes;
            }

            foregrounds[tab_count][name_count] = foreground;
            name_count += 1;
        }

        tabs[tab_count] = .{
            .tab_id = tab.tab_id,
            .pane_count = tab.pane_count,
            .label = tab.label,
            .foregrounds = foregrounds[tab_count][0..name_count],
        };

        tab_count += 1;
    }

    const reconciliation = try self.model.reconcileWorkspace(
        .{
            .workspace = snapshot.workspace,
            .name = snapshot.name,
            .tabs = tabs[0..tab_count],
        },
    );
    for (reconciliation.removed_tabs.slice()) |location| {
        self.model.request_lifecycle.tracker.ignoreTab(location.tab_id);
    }

    for (reconciliation.removed_panes.slice()) |pane_id| {
        self.releasePaneResources(pane_id);
    }

    const active = self.model.tabs.activeSlot() orelse return error.StaleWorkspaceReconciliation;
    if (reconciliation.active_tab_changed) {
        _ = self.model.forgetReportedPaneFocus();
        var panes = self.model.panes.iterate(self.model.tabs.location[active].tab_id);
        while (panes.next()) |pane| {
            try self.graphics.setPaneVisible(pane.id, true);
        }

        try self.synchronizeActivePane();
    }

    if (self.model.request_lifecycle.tracker.has(.tab_snapshot)) {
        return;
    }

    if (reconciliation.active_tab_changed or !reconciliation.active_snapshot_loaded) {
        try self.requestTabSnapshot(reconciliation.active);
        return;
    }

    try self.resizeAttachedPanes(active, self.geometry().area);
}

fn completeTabCreation(self: *AttachedClient, created: core.TabCreated) !data.TabCreation {
    const continuation = self.model.request_lifecycle.tracker.take(created.request_id) orelse
        return error.UnexpectedTabCreated;
    const requested = switch (continuation) {
        .create_tab => |creation| creation,
        else => return error.UnexpectedTabCreated,
    };

    if (!std.meta.eql(requested.workspace, created.location.workspace)) {
        return error.UnexpectedTabCreated;
    }

    const creation = try self.model.createTab(
        .{
            .created = .{
                .location = created.location,
                .position = created.position,
                .label = created.label,
                .root_pane_id = created.root_pane_id,
                .kind = created.kind,
                .pane_generation = created.pane_generation,
            },
            .size = requested.size,
        },
    );
    try self.detachTab(creation.previous);
    try self.synchronizeActivePane();

    if (created.kind == .agent) {
        try self.queryAgentThread(created.root_pane_id);
    }

    return creation;
}

fn completeTabRename(self: *AttachedClient, renamed: core.TabRenamed) !data.Change {
    const continuation = self.model.request_lifecycle.tracker.take(renamed.request_id) orelse
        return error.UnexpectedTabRenamed;
    const expected_location = switch (continuation) {
        .rename_tab => |location| location,
        else => return error.UnexpectedTabRenamed,
    };

    if (!std.meta.eql(expected_location, renamed.location)) {
        return error.UnexpectedTabRenamed;
    }

    return self.model.renameTab(
        .{
            .location = renamed.location,
            .label = renamed.label,
        },
    ) catch return error.UnexpectedTabRenamed;
}

fn requestTabClose(self: *AttachedClient) !bool {
    if (self.model.request_lifecycle.tracker.has(.tab_operation)) {
        return false;
    }

    const location = self.model.activeTabLocation() orelse return false;
    const required = try self.tabDetachmentCapacity(location);
    try self.model.request_lifecycle.ensureCanStart(2);
    if (1 + required > self.runtime_transport.outbox.availableCapacity()) {
        return error.ClientOutboxFull;
    }

    self.detachTab(location) catch |err| {
        _ = try self.recoverTabSnapshot(location);
        return err;
    };

    self.sendTabClose(
        .{
            .location = location,
        },
    ) catch |err| {
        _ = try self.recoverTabSnapshot(location);
        return err;
    };

    return true;
}

fn recoverTabClose(self: *AttachedClient, location: core.TabLocation) !bool {
    const active = self.model.activeTabLocation() orelse return false;
    if (!std.meta.eql(active, location)) {
        return false;
    }

    _ = try self.recoverTabSnapshot(location);
    return true;
}

fn completeTabClose(self: *AttachedClient, closed: core.TabClosed) !TabCloseOutcome {
    const trigger: data.TabCloseRemovalTrigger = if (closed.request_id == .none)
        .lifecycle
    else requested: {
        const continuation = self.model.request_lifecycle.tracker.take(closed.request_id) orelse
            return error.UnexpectedTabClosed;
        const expected_location = switch (continuation) {
            .close_tab => |location| location,
            .ignored => return .ignored,
            else => return error.UnexpectedTabClosed,
        };

        if (!std.meta.eql(expected_location, closed.location)) {
            return error.UnexpectedTabClosed;
        }

        break :requested .requested;
    };

    const command: data.ApplyTabRemoval = .{
        .location = closed.location,
        .workspace_removed = closed.workspace_closed,
        .previous_workspace = closed.previous_workspace,
        .trigger = trigger,
    };

    try data.tab_close.validateWorkspaceTransition(command);
    const commit = try self.model.removeTab(
        .{
            .location = command.location,
            .workspace_removed = command.workspace_removed,
        },
    );
    if (commit == .stale and command.trigger == .requested) {
        return switch (commit.stale.absence) {
            .workspace => error.UnexpectedWorkspace,
            .tab => error.UnexpectedTab,
        };
    }

    const removal = switch (commit) {
        .stale => |stale| {
            self.model.request_lifecycle.tracker.ignoreTab(stale.location.tab_id);
            return .applied;
        },
        .removed => |removed| removed,
    };

    self.model.request_lifecycle.tracker.ignoreTab(removal.removed.tab_id);
    for (removal.panes.slice()) |pane_id| {
        self.releasePaneResources(pane_id);
    }

    if (removal.was_active) {
        _ = self.model.forgetReportedPaneFocus();
        if (removal.active) |location| {
            const active = self.model.tabs.find(location.tab_id) orelse return error.StaleTabRemoval;
            var panes = self.model.panes.iterate(self.model.tabs.location[active].tab_id);
            while (panes.next()) |pane| {
                try self.graphics.setPaneVisible(pane.id, true);
            }

            try self.synchronizeActivePane();
            _ = try self.recoverTabSnapshot(location);
        }
    }

    if (!removal.workspace_removed) {
        return .applied;
    }

    self.model.navigation_history.forget(removal.removed.workspace);
    const previous = command.previous_workspace orelse return .exit;
    _ = try self.requestWorkspaceSwitch(
        .{
            .workspace = previous,
        },
        .canonical_follow,
    );
    return .applied;
}

fn sendTabClose(self: *AttachedClient, intent: data.TabCloseIntent) !void {
    const request_id = try self.model.request_lifecycle.nextId();

    try self.sendRuntimeRequest(
        .{
            .registration = .{
                .request_id = request_id,
                .continuation = .{
                    .close_tab = intent.location,
                },
            },
            .message = .{
                .close_tab = .{
                    .request_id = request_id,
                    .location = intent.location,
                },
            },
        },
    );
}

/// Preflights departure, queues the open, then retires the previous projection.
fn requestWorkspaceSwitch(self: *AttachedClient, target: WorkspaceSwitchTarget, authority: WorkspaceSwitchAuthority) !data.WorkspaceDeparture {
    const size = data.multiplexer.rectSize(self.geometry().area) orelse return error.TerminalTooSmall;
    const command: data.WorkspaceHandoff = switch (target) {
        .workspace => |workspace| selected: {
            const bookmark = self.model.navigation_history.find(
                .{
                    .workspace = workspace,
                },
            );
            break :selected .{
                .target = if (bookmark) |remembered| .{
                    .pane = remembered.pane_id,
                } else .{
                    .workspace = workspace,
                },
                .fallback_workspace = workspace,
                .size = size,
            };
        },
        .pane => |pane| .{
            .target = .{
                .pane = pane.pane_id,
            },
            .fallback_workspace = pane.fallback_workspace,
            .size = size,
        },
    };

    switch (authority) {
        .requested_departure => {
            if (!self.model.request_lifecycle.tracker.isEmpty()) {
                return error.WorkspaceSwitchWhileRequestPending;
            }
        },
        .canonical_follow => {
            if (self.model.workspace != null) {
                return error.WorkspaceStillActive;
            }
        },
    }

    try self.model.request_lifecycle.ensureCanStart(2);
    var required: usize = 1;
    for (self.model.tabs.location[0..self.model.tabs.count]) |location| {
        required += try self.tabDetachmentCapacity(location);
    }

    if (required > self.runtime_transport.outbox.availableCapacity()) {
        return error.ClientOutboxFull;
    }

    for (self.model.tabs.location[0..self.model.tabs.count]) |location| {
        self.detachTab(location) catch |err| {
            self.restoreDepartingWorkspace() catch {};
            return err;
        };
    }

    self.sendWorkspaceOpen(command) catch |err| {
        self.restoreDepartingWorkspace() catch {};
        return err;
    };

    const departure = self.model.departWorkspace();
    self.releaseWorkspace(&departure);
    return departure;
}

/// Repairs the visible tab after a partial departure; callers preserve the original error.
fn restoreDepartingWorkspace(self: *AttachedClient) !void {
    const location = self.model.activeTabLocation() orelse return;
    const plan = try self.model.planTabDetachment(location);
    for (plan.slice()) |pane| {
        try self.graphics.setPaneVisible(pane.pane_id, true);
    }

    _ = try self.recoverTabSnapshot(location);
}

/// Retries a missing remembered pane once, clearing the fallback on the new request.
fn recoverWorkspaceSwitch(self: *AttachedClient, fallback_workspace: ?core.WorkspaceId, code: core.FailureCode) !WorkspaceRecovery {
    const workspace = fallback_workspace orelse return .unrecoverable;
    if (code != .pane_not_found) {
        return .unrecoverable;
    }

    self.model.navigation_history.forget(
        .{
            .workspace = workspace,
        },
    );
    try self.sendWorkspaceOpen(
        .{
            .target = .{
                .workspace = workspace,
            },
            .fallback_workspace = null,
            .size = data.multiplexer.rectSize(self.geometry().area) orelse return error.TerminalTooSmall,
        },
    );
    return .retried;
}

/// Correlates the open before its owned message enters the runtime outbox.
fn sendWorkspaceOpen(self: *AttachedClient, command: data.WorkspaceHandoff) !void {
    const request_id = try self.model.request_lifecycle.nextId();
    try self.sendRuntimeRequest(
        .{
            .registration = .{
                .request_id = request_id,
                .continuation = .{
                    .initial_open = .{
                        .fallback_workspace = command.fallback_workspace,
                    },
                },
            },
            .message = .{
                .open_pane = .{
                    .request_id = request_id,
                    .target = command.target,
                    .size = command.size,
                    .launch = null,
                },
            },
        },
    );
}

/// Restores a bookmark layout only when the runtime selected that exact tab.
fn workspaceArrival(history: *const data.NavigationHistory, opened: data.OpenedPane, size: core.TerminalSize) data.WorkspaceArrival {
    const bookmark = history.find(opened.location.workspace);
    const saved_layout = if (bookmark) |remembered|
        if (std.meta.eql(remembered.location, opened.location)) remembered.tab_layout else null
    else
        null;

    return .{
        .pane_id = opened.pane_id,
        .location = opened.location,
        .size = size,
        .saved_layout = saved_layout,
    };
}

/// Remembers departed navigation before releasing pane resources.
fn releaseWorkspace(self: *AttachedClient, departure: *const data.WorkspaceDeparture) void {
    if (departure.bookmark) |bookmark| {
        self.model.navigation_history.remember(
            .{
                .location = bookmark.location,
                .pane_id = bookmark.pane_id,
                .tab_layout = bookmark.tab_layout,
            },
        );
    }

    for (departure.panes.slice()) |pane_id| {
        self.releasePaneResources(pane_id);
    }

    _ = self.model.forgetReportedPaneFocus();
}

/// Validates the committed root before resuming input and requesting canonical snapshots.
fn activateWorkspace(self: *AttachedClient, activation: data.WorkspaceActivation) !void {
    const active = self.model.tabs.activeSlot() orelse return error.StaleWorkspaceActivation;
    const root = self.model.panes.findInConst(self.model.tabs.location[active].tab_id, activation.pane_id) orelse return error.StaleWorkspaceActivation;
    const version = self.model.version();
    if (!std.meta.eql(self.model.tabs.location[active], activation.location) or
        self.model.panes.countIn(self.model.tabs.location[active].tab_id) != 1 or
        self.model.tabs.layout[active].focused() != activation.pane_id or
        !std.meta.eql(root.location, activation.location) or
        !root.attached or
        version.workspace != activation.workspace_revision or
        version.tabs != activation.tabs_revision or
        version.active_tab != activation.active_tab_revision or
        version.panes != activation.panes_revision or
        version.copy != activation.copy_revision or
        activation.workspace_revision_before +% 1 != activation.workspace_revision or
        activation.tabs_revision_before +% 1 != activation.tabs_revision or
        activation.active_tab_revision_before +% 1 != activation.active_tab_revision or
        activation.panes_revision_before +% 1 != activation.panes_revision or
        activation.copy_revision_before +% @intFromBool(activation.copy_released) != activation.copy_revision)
    {
        return error.StaleWorkspaceActivation;
    }

    try self.synchronizeActivePane();
    self.model.to_host.resume_input = true;
    try self.requestWorkspaceSnapshot(activation.location.workspace);
    try self.requestTabSnapshot(activation.location);
}

/// Consumes one correlated runtime completion before committing canonical state.
fn completeTabMove(self: *AttachedClient, moved: core.TabMoved) !data.Change {
    const continuation = self.model.request_lifecycle.tracker.take(moved.request_id) orelse
        return error.UnexpectedTabMoved;
    const expected_location = switch (continuation) {
        .move_tab => |location| location,
        else => return error.UnexpectedTabMoved,
    };

    if (!std.meta.eql(expected_location, moved.location)) {
        return error.UnexpectedTabMoved;
    }

    return self.model.applyTabPosition(moved.location, moved.position) catch return error.UnexpectedTabMoved;
}

/// Applies validated cells and acknowledges ownership before host resources.
fn applyPaneFrame(self: *AttachedClient, frame: core.FrameView) !data.PaneFrameOutcome {
    core.profiling.add(.client_apply_frame, 1);
    const profile_started = core.profiling.start(self.io);
    defer core.profiling.finish(self.io, .client_frame, profile_started);
    const started = core.now(self.io);
    const outcome = try self.model.applyPaneFrame(frame);
    switch (outcome) {
        .detached => {},
        .resync => |recovery| try self.requestPaneFrameSnapshot(recovery),
        .applied => |commit| {
            try self.acknowledgePaneFrame(
                .{
                    .pane_id = commit.pane_id,
                    .frame_id = commit.frame_id,
                },
            );
            if (self.graphics.paneVisible(commit.pane_id) != commit.graphics_visible) {
                try self.graphics.setPaneVisible(commit.pane_id, commit.graphics_visible);
            }

            if (self.model.tabs.activeSlot() != null) {
                try self.synchronizeActivePane();
            }
        },
    }

    if (outcome == .applied) {
        const commit = outcome.applied;
        if (comptime core.enabled) {
            self.telemetry.metrics.frames += 1;
            self.telemetry.metrics.frame_cells += commit.cells;
            self.telemetry.metrics.frame_spans += commit.spans;
            self.telemetry.metrics.snapshots += @intFromBool(commit.snapshot);
            self.telemetry.metrics.apply.observe(core.elapsed(started, core.now(self.io)));
        }

        if (self.reconcileAttachmentFrame(commit.pane_id)) {
            self.model.to_host.invalidate_placements = true;
            if (self.model.tabs.activeSlot()) |tab| {
                try self.resizeAttachedPanes(tab, self.geometry().area);
            }
        }
    }

    return outcome;
}

fn acknowledgePaneFrame(self: *AttachedClient, ack: core.FrameAck) !void {
    const started = core.now(self.io);
    try self.sendRuntime(
        .{
            .frame_ack = ack,
        },
    );

    if (comptime core.enabled) {
        self.telemetry.metrics.ack_enqueue.observe(core.elapsed(started, core.now(self.io)));
    }
}

fn requestPaneFrameSnapshot(self: *AttachedClient, recovery: data.PaneFrameRecovery) !void {
    try self.sendRuntime(
        .{
            .request_snapshot = .{
                .pane_id = recovery.pane_id,
                .known_frame_id = recovery.known_frame_id,
            },
        },
    );
}

/// Stores one decoded terminal progress report and maintains animation liveness.
fn applyPaneProgress(self: *AttachedClient, message: core.PaneProgress) !?data.PaneProgressCommit {
    const commit = self.model.updatePaneProgress(message) orelse return null;
    _ = try self.synchronizeSidebarAnimation();
    return commit;
}

/// Revalidates the source pane, applies the directional focus, and reports the
/// result to the control connection through the runtime.
fn completePaneFocusCommand(self: *AttachedClient, command: core.PaneFocusCommand) !void {
    const current = self.model.planPaneInput(.focused);
    if (current == null or current.?.pane_id != command.pane_id) {
        return self.sendPaneFocusCompletion(
            command,
            .{
                .outcome = .source_not_focused,
                .focused_pane_id = .invalid,
            },
        );
    }

    const focus = try self.applyPaneFocus(
        .{
            .target = .{
                .direction = paneFocusDirection(command.direction),
            },
            .area = self.geometry().area,
        },
    );
    if (focus) |changed| {
        return self.sendPaneFocusCompletion(
            command,
            .{
                .outcome = .focused,
                .focused_pane_id = changed.focused,
            },
        );
    }

    return self.sendPaneFocusCompletion(
        command,
        .{
            .outcome = .no_neighbor,
            .focused_pane_id = command.pane_id,
        },
    );
}

fn sendPaneFocusCompletion(self: *AttachedClient, command: core.PaneFocusCommand, completion: data.PaneFocusCompletion) !void {
    try self.sendRuntime(
        .{
            .complete_pane_focus = .{
                .requester = command.requester,
                .request_id = command.request_id,
                .pane_id = command.pane_id,
                .pane_generation = command.pane_generation,
                .outcome = completion.outcome,
                .focused_pane_id = completion.focused_pane_id,
            },
        },
    );
}

fn paneFocusDirection(value: core.PaneDirection) data.LayoutDirection {
    return switch (value) {
        .left => .left,
        .right => .right,
        .up => .up,
        .down => .down,
    };
}

/// Requests closure without mutating runtime-owned pane membership.
fn requestPaneClose(self: *AttachedClient) !?data.PaneClosure {
    if (self.model.request_lifecycle.tracker.has(.pane_operation)) {
        return null;
    }

    const closure = self.model.planPaneClosure() orelse return null;
    const request_id = try self.model.request_lifecycle.nextId();
    try self.sendRuntimeRequest(
        .{
            .registration = .{
                .request_id = request_id,
                .continuation = .{
                    .close_pane = .{
                        .pane_id = closure.pane_id,
                        .location = closure.location,
                    },
                },
            },
            .message = .{
                .close_pane = .{
                    .request_id = request_id,
                    .pane_id = closure.pane_id,
                },
            },
        },
    );
    return closure;
}

/// Commits authoritative retirement and performs idempotent cleanup for late exits.
fn applyPaneExit(self: *AttachedClient, exited: core.PaneExited) !data.PaneExit {
    const transition = self.model.retirePane(exited.pane_id);
    _ = self.model.request_lifecycle.tracker.ignoreAttachment(exited.pane_id);
    _ = self.model.request_lifecycle.tracker.completePaneClose(exited.pane_id);
    self.releasePaneResources(exited.pane_id);

    const retirement = switch (transition) {
        .retired => |retirement| retirement,
        .stale => return transition,
    };

    if (!retirement.active) {
        return transition;
    }

    self.model.to_host.invalidate_placements = true;
    try self.synchronizeActivePane();
    if (!retirement.tab_empty) {
        const tab = self.model.tabs.find(retirement.location.tab_id) orelse return error.StalePaneExit;
        try self.resizeAttachedPanes(tab, self.geometry().area);
    }

    return transition;
}

/// Enters copy mode on the attached focused pane.
fn enterCopyMode(self: *AttachedClient) bool {
    const tab = self.model.tabs.activeSlot() orelse return false;
    const pane = data.tab_layout.focusedPaneConst(&self.model, tab) orelse return false;
    if (pane.kind == .agent) {
        if (!pane.attached or self.model.copyModeActive() or self.model.name_prompt.active() or self.model.pane_paste != null) {
            return false;
        }

        return self.host_input_source.enterThreadCopyMode(pane.id);
    }

    return self.model.enterCopyMode();
}

/// Applies one runtime search reply to the active copy-mode state.
fn applyPaneMatches(self: *AttachedClient, view: core.PaneMatchesView) !data.CopyModeOutcome {
    var storage: [core.max_search_matches]core.SearchMatch = undefined;
    var count: usize = 0;
    var iterator = view.matches();
    while (try iterator.next()) |match| {
        if (count == storage.len) {
            break;
        }
        storage[count] = match;
        count += 1;
    }

    return self.applyCopyMode(
        .{
            .matches = .{
                .pane_id = view.pane_id,
                .matches = storage[0..count],
            },
        },
    );
}

/// Opens the palette and requests the unfiltered newest history.
fn beginHistoryPalette(self: *AttachedClient) !bool {
    if (!self.openNamePrompt(.history_palette)) {
        return false;
    }

    history_browser.begin(
        &self.model,
        .{
            .enter_runs = self.model.config.history_enter_runs,
            .match_fuzzy = !self.model.config.history_match_fts,
        },
    );
    try self.queryHistory("");
    return true;
}

fn requestHistoryPage(self: *AttachedClient, query: []const u8) !void {
    const request_id = try self.model.request_lifecycle.nextId();

    var owned: data.OwnedHistoryQuery = .{
        .request_id = request_id,
        .query_len = @intCast(@min(query.len, data.OwnedHistoryQuery.max_query_bytes)),
        .author = if (self.model.config.history_show_agent_commands) .all else .human,
        .match = if (self.model.config.history_match_fts) .fts else .fuzzy,
        .limit = core.max_history_results,
        .offset = self.model.history_palette.pending_offset,
        .snapshot_id = self.model.history_palette.snapshot_id,
    };
    @memcpy(owned.query[0..owned.query_len], query[0..owned.query_len]);
    resolveHistoryScope(&self.model, &owned);
    if (!self.model.history_palette.beginPageRequest(core.raw(request_id), owned.scope)) {
        return;
    }

    self.sendRuntime(
        .{
            .query_history = owned,
        },
    ) catch |err| {
        _ = self.model.history_palette.fail(
            .{
                .request_id = request_id,
                .code = .resource_limit,
                .message = "History request queue is full; retry",
            },
        );
        if (err != error.ClientOutboxFull) {
            return err;
        }
    };
}

fn resolveHistoryScope(model: *const data.ClientModel, owned: *data.OwnedHistoryQuery) void {
    const prompt = model.name_prompt.currentConst() orelse return;
    if (prompt.target() != .history) {
        return;
    }

    switch (prompt.scope()) {
        .global => {},
        .workspace => {
            const location = model.workspace orelse return;
            const workspace = switch (location) {
                .workspace => |workspace| workspace,
                .worktree => return,
            };

            const list = &model.workspace_list_snapshot;
            const index = list.indexOf(workspace) orelse return;
            const path = list.pathAt(index);
            if (path.len == 0 or path.len > data.OwnedHistoryQuery.max_scope_bytes) {
                return;
            }

            owned.scope = .workspace;
            @memcpy(owned.scope_value[0..path.len], path);
            owned.scope_value_len = @intCast(path.len);
        },
        .cwd => {
            const active = model.tabs.activeSlot() orelse return;
            const pane = data.tab_layout.focusedPaneConst(model, active) orelse return;
            const cwd = pane.cwdSlice();
            if (cwd.len == 0 or cwd.len > data.OwnedHistoryQuery.max_scope_bytes) {
                return;
            }

            owned.scope = .cwd;
            @memcpy(owned.scope_value[0..cwd.len], cwd);
            owned.scope_value_len = @intCast(cwd.len);
        },
        .pane => {
            const active = model.tabs.activeSlot() orelse return;
            const pane = data.tab_layout.focusedPaneConst(model, active) orelse return;
            owned.scope = .pane;
            owned.pane_id = pane.id;
        },
    }
}

/// Applies one runtime reply to the palette model. Stale replies and replies
/// arriving after the palette closed change nothing visible.
fn applyHistoryResults(self: *AttachedClient, view: core.HistoryResultsView) !bool {
    var storage: [core.max_history_results]core.HistoryEntry = undefined;
    var count: usize = 0;
    var iterator = view.entries();
    while (try iterator.next()) |entry| {
        if (count == storage.len) {
            break;
        }

        storage[count] = entry;
        count += 1;
    }

    const changed = history_browser.apply(
        &self.model,
        .{
            .request_id = core.raw(view.request_id),
            .entries = storage[0..count],
            .snapshot_id = view.snapshot_id,
            .has_more = view.has_more,
            .now_ms = @intCast(std.Io.Timestamp.now(self.io, .real).toMilliseconds()),
        },
    );
    if (changed) {
        try self.refreshHistoryInspection();
    }

    return changed;
}

fn enqueueHistoryRequest(self: *AttachedClient, message: data.outbox_support.Message, request_id: core.RequestId) !void {
    self.sendRuntime(message) catch |err| {
        _ = self.model.history_palette.fail(
            .{
                .request_id = request_id,
                .code = .resource_limit,
                .message = "History queue is full; change selection or retry",
            },
        );
        if (err != error.ClientOutboxFull) {
            return err;
        }
    };
}

/// Requeries the palette after the runtime confirmed a deletion.
fn completeHistoryPrune(self: *AttachedClient, confirmation: core.HistoryPruned) !bool {
    if (!history_browser.pruned(&self.model, core.raw(confirmation.request_id))) {
        return false;
    }

    try self.queryHistory(self.model.name_prompt.currentConst().?.field.text());
    return true;
}

/// Delivers one bounded semantic notification through the runtime and records
/// the continuation consumed by its delivery report.
fn requestNotificationDelivery(self: *AttachedClient, notification: *const data.Notification) !core.RequestId {
    const request_id = try self.model.request_lifecycle.nextId();
    try self.sendNotificationRequest(
        .{
            .request_id = request_id,
            .notification = .{
                .level = notification.level,
                .duration_ms = notification.duration_ms,
                .target = notification.target,
                .title = notification.title(),
                .message = notification.message(),
            },
        },
    );

    return request_id;
}

/// Consumes one correlated runtime delivery report and applies its policy.
fn completeNotificationDelivery(self: *AttachedClient, shown: core.NotificationShown) !data.NotificationDeliveryOutcome {
    const continuation = self.model.request_lifecycle.tracker.take(shown.request_id) orelse
        return error.UnexpectedNotificationReply;
    if (continuation != .notification) {
        return error.UnexpectedNotificationReply;
    }

    if (shown.delivered_clients != 0) {
        return .delivered;
    }

    try self.publishNotificationNow(
        .{
            .level = .failure,
            .title = "Notification not delivered",
            .message = "No connected client could accept the notification",
        },
    );
    return .undelivered;
}

/// Translates and publishes one notification pushed by the runtime.
fn applyRuntimeNotification(self: *AttachedClient, notification: core.Notification) !data.NotificationPublication {
    return self.publishNotification(
        core.monotonic(self.io),
        .{
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
                .pane => |pane_id| .{
                    .focus_pane = pane_id,
                },
                .tab => |tab_id| .{
                    .select_tab = tab_id,
                },
                .workspace => |workspace_id| .{
                    .select_workspace = workspace_id,
                },
            },
            .duration_ns = @as(u64, notification.duration_ms) * std.time.ns_per_ms,
        },
    );
}

/// Surfaces one published notice through the configured host channel. The
/// in-app center always shows it; the host port owns `terminal` and `system`.
fn deliverHostNotification(self: *AttachedClient, input: data.NotificationInput) !void {
    if (self.model.config.notification_delivery == .telar) {
        return;
    }

    const payload: data.NotificationPayload = .init(input.title, input.message);
    switch (self.model.config.notification_delivery) {
        .telar => unreachable,
        .terminal => try self.model.to_host.push(.{ .terminal_notification = payload }),
        // A system notice is best effort; a saturated inbox drops it.
        .system => self.workers.start(.{ .system_notification = payload }) catch {},
    }
}

/// Advances every notification lifecycle to one monotonic timestamp.
fn advanceNotifications(self: *AttachedClient, now_ns: u64) !?data.NotificationChange {
    const change = self.model.advanceNotifications(now_ns);
    try self.scheduleNotificationTimer();
    return change;
}

/// Activates one current notification identity and follows its target at most
/// once.
fn activateNotification(self: *AttachedClient, id: data.NotificationId, now_ns: u64) !?data.NotificationActivation {
    const activation = self.model.activateNotification(id, now_ns) orelse return null;
    try self.scheduleNotificationTimer();
    try self.navigateNotification(activation.target);
    return activation;
}

/// Dismisses one current notification identity without navigation.
fn dismissNotification(self: *AttachedClient, id: data.NotificationId, now_ns: u64) !?data.NotificationChange {
    const change = self.model.dismissNotification(id, now_ns) orelse return null;
    try self.scheduleNotificationTimer();
    return change;
}

fn navigateNotification(self: *AttachedClient, target: data.NotificationTarget) !void {
    switch (target) {
        .none => {},
        .select_tab => |tab_id| {
            _ = try self.selectTab(
                .{
                    .target = .{
                        .tab_id = tab_id,
                    },
                },
            );
        },
        .select_workspace => |workspace| {
            _ = try self.selectWorkspace(
                .{
                    .workspace = workspace,
                },
            );
        },
        .focus_pane => |pane_id| {
            _ = try self.applyPaneFocus(
                .{
                    .target = .{
                        .pane_id = pane_id,
                    },
                    .area = self.geometry().area,
                },
            );
        },
    }
}

/// Translates one runtime sound and applies it to an exact current agent.
fn applyAgentSound(self: *AttachedClient, notification: core.AgentSoundNotification) !AgentSoundOutcome {
    if (!(self.model.agent_snapshot.find(
        .{
            .pane_id = notification.pane_id,
            .pane_generation = notification.pane_generation,
        },
    ) != null)) {
        return .stale;
    }

    switch (self.model.sound_playback.request(notification.sound)) {
        .ignored, .queued => {},
        .start => |kind| try self.startAgentSound(kind),
    }

    return .accepted;
}

fn startAgentSound(self: *AttachedClient, kind: core.AgentSound) !void {
    self.workers.start(.{ .sound = kind }) catch |err| {
        self.model.sound_playback.schedulingFailed();
        return err;
    };
}

/// Consumes the single bootstrap snapshot, restores client-owned preferences
/// and sends the initial attach-or-create request with the restored geometry.
fn restoreClientLayout(self: *AttachedClient, snapshot: core.ClientLayoutSnapshotView) !void {
    if (self.model.client_layouts.snapshot_received) {
        return error.DuplicateClientLayoutSnapshot;
    }

    var saved_layouts: data.SavedLayouts = .{};
    var history: data.NavigationHistory = .{};
    const restored = if (snapshot.restored)
        try parseClientLayoutSnapshot(
            snapshot,
            &saved_layouts,
            &history,
        )
    else
        null;

    if (snapshot.restored) {
        if (self.model.restoreSidebarLayout(snapshot.sidebar_visible, snapshot.sidebar_width)) |change| {
            try self.deliverSidebarLayout(change);
        }

        _ = self.model.setWorkspaceListCollapsed(snapshot.workspace_list_collapsed);

        self.model.restoreClientLayouts(saved_layouts);
        self.model.navigation_history = history;
    }

    const size = data.multiplexer.rectSize(self.geometry().area) orelse
        return error.TerminalTooSmall;
    const request = self.initialPaneRequest(restored, size);
    try self.sendRuntimeRequest(request);
    try self.model.client_layouts.markSnapshotReceived();
}

fn parseClientLayoutSnapshot(snapshot: core.ClientLayoutSnapshotView, layouts: *data.SavedLayouts, history: *data.NavigationHistory) !?data.SavedLayout {
    var restored_active: ?data.SavedLayout = null;
    var tabs = snapshot.tabs();
    while (try tabs.next()) |tab| {
        const saved: data.SavedLayout = .{
            .location = tab.location,
            .pane_id = tab.focused_pane,
            .workspace_active = tab.workspace_active,
            .layout = try data.WorkspaceLayout.fromClientLayout(tab),
        };

        try layouts.remember(saved);
        if (tab.workspace_active) {
            history.remember(
                .{
                    .location = tab.location,
                    .pane_id = tab.focused_pane,
                    .tab_layout = saved.layout,
                },
            );
        }

        if (snapshot.active_tab) |active_location| {
            if (std.meta.eql(tab.location, active_location)) {
                restored_active = saved;
            }
        }
    }

    if (snapshot.active_tab != null and restored_active == null) {
        return error.InvalidClientLayoutActiveTab;
    }

    return restored_active;
}

fn initialPaneRequest(self: *AttachedClient, restored: ?data.SavedLayout, size: core.TerminalSize) data.ConnectionDelivery {
    const fallback_workspace: ?core.WorkspaceId = if (restored) |saved| switch (saved.location.workspace) {
        .workspace => |workspace_id| workspace_id,
        .worktree => null,
    } else null;

    return .{
        .registration = .{
            .request_id = lifecycle.initial_request_id,
            .continuation = .{
                .initial_open = .{
                    .fallback_workspace = fallback_workspace,
                },
            },
        },
        .message = .{
            .open_pane = .{
                .request_id = lifecycle.initial_request_id,
                .target = if (restored) |saved| .{
                    .pane = saved.pane_id,
                } else .default,
                .size = size,
                .launch = if (restored == null) .{
                    .cwd = self.options.cwd,
                    .arguments = self.options.arguments,
                } else null,
            },
        },
    };
}

/// Resolves disposable client state and applies one validated runtime resync.
/// The client loop maps only the returned `exit` outcome to process status.
fn applyResyncRequirement(self: *AttachedClient, required: core.ResyncRequired) !ResyncOutcome {
    if (required.workspace_closed) {
        self.model.navigation_history.forget(required.workspace);
        const previous = required.previous_workspace orelse return .exit;
        _ = try self.requestWorkspace(previous);
        return .handoff_requested;
    }

    const projected = self.model.workspace orelse return error.UnexpectedResync;
    if (!std.meta.eql(projected, required.workspace)) {
        return error.UnexpectedResync;
    }

    if (self.model.request_lifecycle.tracker.has(.workspace_snapshot)) {
        return .coalesced;
    }

    try self.requestWorkspaceSnapshot(required.workspace);
    return .snapshot_requested;
}

/// Opens the palette with an empty request and no suggestion.
fn beginSuggestion(self: *AttachedClient) !bool {
    if (!self.openNamePrompt(.suggest_palette)) {
        return false;
    }

    self.model.suggestion.begin();
    return true;
}

fn suggestionPane(model: *const data.ClientModel) ?core.PaneId {
    const active = model.tabs.activeSlot() orelse return null;
    const pane = data.tab_layout.focusedPaneConst(model, active) orelse return null;
    return pane.id;
}

/// Commits one decoded proxy state and announces only semantic transitions.
fn applyProxyStatus(self: *AttachedClient, message: core.ProxyStatus) !?data.ProxyStatusCommit {
    const commit = self.model.reconcileProxyStatus(message) orelse return null;

    const trust_only = commit.previous == commit.active and commit.previous_scope == commit.scope;
    try self.publishNotificationNow(
        .{
            .level = if (commit.active or commit.system_trusted) .warning else .info,
            .title = if (trust_only)
                if (commit.system_trusted) "Proxy CA trusted by system" else "Proxy CA removed from system trust"
            else if (commit.active)
                "TLS interception active"
            else
                "TLS interception stopped",
            .message = if (trust_only)
                if (commit.system_trusted) "The short-lived Telar CA is installed" else "The Telar CA is no longer installed"
            else if (commit.active)
                "Agent network traffic is being observed"
            else
                "Agent network traffic is no longer observed",
            .duration_ns = if (commit.active or commit.system_trusted)
                7 * std.time.ns_per_s
            else
                data.notifications.default_duration_ns,
        },
    );
    return commit;
}

/// Maps one validated wire view into bounded agent inputs and synchronizes
/// dependent client state after committing the canonical revision.
fn applyAgentSnapshot(self: *AttachedClient, snapshot: core.AgentSnapshotView) !?data.AgentSnapshotCommit {
    var entries: [core.max_agent_snapshot_entries]data.AgentInput = undefined;
    var count: usize = 0;
    var iterator = snapshot.entries();
    while (try iterator.next()) |entry| {
        entries[count] = .{
            .key = .{
                .pane_id = entry.pane_id,
                .pane_generation = entry.pane_generation,
            },
            .location = entry.location,
            .pane_index = entry.pane_index,
            .workspace_label = entry.workspace_label,
            .tab_label = entry.tab_label,
            .session_title = entry.session_title,
            .title_source = entry.title_source,
            .title_state = entry.title_state,
            .cwd_label = entry.cwd_label,
            .provider = entry.provider,
            .provider_name = entry.provider_name,
            .display_name = entry.display_name,
            .icon = entry.icon,
            .attachments = entry.attachments,
            .status = entry.status,
            .blocked_reason = entry.blocked_reason,
            .last_event = entry.last_event,
            .status_age_s = entry.status_age_s,
        };
        count += 1;
    }

    const commit = try self.model.reconcileAgentSnapshot(
        .{
            .revision = snapshot.revision,
            .agents = entries[0..count],
        },
    ) orelse return null;
    _ = try self.synchronizePaneAttachments();

    var alert_count: usize = 0;
    const current = &self.model.agent_snapshot;
    for (commit.status_changes.slice()) |change| {
        if (alert_count == data.notifications.max_items) {
            break;
        }

        var message_buffer: [96]u8 = undefined;
        const label = if (current.find(change.key)) |agent| agent.displayName() else core.generic_display_name;
        const alert = agent_snapshot_delivery.alertInput(
            change,
            label,
            &message_buffer,
        ) orelse continue;
        try self.publishNotificationNow(alert);
        alert_count += 1;
    }

    _ = try self.synchronizeSidebarAnimation();
    return commit;
}

/// Reconciles physical graphics and semantic fallback, recovering bounded ingress failures.
fn applyPaneGraphics(self: *AttachedClient, command: data.PaneGraphicsCommand) !data.PaneGraphicsOutcome {
    if (comptime core.enabled) {
        switch (command) {
            .image, .shared_image => self.telemetry.metrics.graphics_images += 1,
            else => {},
        }
    }

    const pane_id = command.paneId();
    const resource = try pane_graphics.applyResources(self.graphics, command);

    return switch (resource) {
        .unchanged => .unchanged,
        .changed => |state| block: {
            if (state.pane_id != pane_id) {
                return error.InvalidPaneGraphicsResult;
            }

            break :block .{
                .applied = .{
                    .pane_id = pane_id,
                    .fallback = self.model.setPaneGraphicsFallback(
                        pane_id,
                        self.model.host.host_capabilities.images != .supported and
                            state.has_graphics,
                    ),
                },
            };
        },
        .resync_required => |recovery_pane| block: {
            if (recovery_pane != pane_id) {
                return error.InvalidPaneGraphicsResult;
            }

            try self.sendRuntime(
                .{
                    .request_graphics_snapshot = .{
                        .pane_id = pane_id,
                    },
                },
            );
            break :block .{
                .resync_requested = pane_id,
            };
        },
        .shared_mapping_failed => |recovery_pane| block: {
            if (recovery_pane != pane_id) {
                return error.InvalidPaneGraphicsResult;
            }

            try self.sendRuntime(
                .{
                    .configure_graphics = .{
                        .shared = false,
                    },
                },
            );
            try self.sendRuntime(
                .{
                    .request_graphics_snapshot = .{
                        .pane_id = pane_id,
                    },
                },
            );
            break :block .{
                .shared_disabled = pane_id,
            };
        },
    };
}

/// Commits a membership-checked layout before delivering its geometry.
fn applyPaneLayout(self: *AttachedClient, request: data.PaneLayoutRequest) !void {
    const focus = try self.model.applyPaneLayout(request);
    try self.deliverPaneFocus(focus, request.area);
}

/// Releases exact pane authorities before physical resources; repeated release is harmless.
fn releasePaneResources(self: *AttachedClient, pane_id: core.PaneId) void {
    _ = self.model.releaseCopyMode(pane_id);
    _ = self.model.releasePanePaste(pane_id);
    _ = self.model.releaseReportedPaneFocus(pane_id);
    self.graphics.clearPane(pane_id);
}

/// Ensures the current model has one future tick when animation is active.
fn synchronizeSidebarAnimation(self: *AttachedClient) !sidebar_animation.Activity {
    if (!self.model.sidebarAnimationActive()) {
        return .inactive;
    }

    try self.scheduleSidebarAnimation();
    return .active;
}

fn scheduleSidebarAnimation(self: *AttachedClient) !void {
    if (self.model.host.animation_frame_ns == null) {
        return;
    }

    const scheduler = &self.model.sidebar_animation_scheduler;
    if (scheduler.pending) {
        return;
    }

    const deadline_ns = core.monotonic(self.io) +| sidebar_animation_interval_ns;
    switch (scheduler.update(self.io, deadline_ns)) {
        .idle, .retained => {},
        .schedule => self.workers.start(.{ .timer = .{ .kind = .sidebar_animation, .scheduler = scheduler } }) catch |err| {
            scheduler.schedulingFailed();
            return err;
        },
    }
}

/// Replaces the pending deadline from current model state and starts at most
/// one inbox producer through the timer port.
fn scheduleNotificationTimer(self: *AttachedClient) !void {
    const scheduler = &self.model.notification_scheduler;
    const now_ns = core.monotonic(self.io);
    const deadline_ns = self.model.notification_center.nextDeadline(
        now_ns,
        self.model.host.animation_frame_ns orelse std.math.maxInt(u64),
    );
    switch (scheduler.update(self.io, deadline_ns)) {
        .idle, .retained => {},
        .schedule => self.workers.start(.{ .timer = .{ .kind = .notification, .scheduler = scheduler } }) catch |err| {
            scheduler.schedulingFailed();

            return err;
        },
    }
}

/// Detaches every tab in stable client order before the event loop exits.
fn detachAllTabs(self: *AttachedClient) !void {
    var locations: [core.max_tabs_per_workspace]core.TabLocation = undefined;
    var count: usize = 0;
    for (self.model.tabs.location[0..self.model.tabs.count]) |location| {
        std.debug.assert(count < locations.len);
        locations[count] = location;
        count += 1;
    }

    for (locations[0..count]) |location| {
        try self.detachTab(location);
    }
}

/// Commits reporting ownership before emitting focus-out and focus-in. Example: `_ = try sync(client);`
fn synchronizeReportedFocus(self: *AttachedClient) !FocusReportOutcome {
    const transition = self.model.syncReportedPaneFocus() orelse return .unchanged;
    if (transition.focus_out) |pane_id| {
        try self.sendRuntimeInput(
            .{
                .pane_id = pane_id,
                .bytes = "\x1b[O",
            },
        );
    }

    if (transition.focus_in) |pane_id| {
        try self.sendRuntimeInput(
            .{
                .pane_id = pane_id,
                .bytes = "\x1b[I",
            },
        );
    }

    return .applied;
}

/// Clears focus ownership before detachment and sends the matching focus-out. Example: `_ = try clear(client);`
fn clearReportedFocus(self: *AttachedClient) !FocusReportOutcome {
    const transition = self.model.clearReportedPaneFocus() orelse return .unchanged;
    if (transition.focus_out) |pane_id| {
        try self.sendRuntimeInput(
            .{
                .pane_id = pane_id,
                .bytes = "\x1b[O",
            },
        );
    }

    return .applied;
}

/// Commits a bounded viewport, then updates graphics and the runtime. Example: `_ = try apply(client, command);`
fn applyPaneViewport(self: *AttachedClient, command: data.PaneViewportCommand) !?data.PaneViewportChange {
    const change = self.model.setPaneViewport(command) orelse return null;
    try self.deliverPaneViewport(change);

    return change;
}

/// Delivers a viewport committed by this or a compound input operation. Example: `try deliver(client, change);`
fn deliverPaneViewport(self: *AttachedClient, change: data.PaneViewportChange) !void {
    const active = self.model.tabs.activeSlot() orelse return error.StalePaneViewport;
    const pane = self.model.panes.findInConst(self.model.tabs.location[active].tab_id, change.pane_id) orelse return error.StalePaneViewport;
    if (!pane.attached or
        pane.scroll.offset != change.offset or
        pane.scroll.atBottom(pane.buffer.h) != change.at_bottom or
        self.model.version().viewport != change.viewport_revision)
    {
        return error.StalePaneViewport;
    }

    try self.graphics.setPaneVisible(change.pane_id, change.at_bottom);
    try self.sendRuntime(
        .{
            .set_pane_viewport = .{
                .pane_id = change.pane_id,
                .offset = change.offset,
            },
        },
    );
}

/// Applies one exact model commit to the view, physical graphics placements
/// and attached runtime pane geometry.
fn deliverSidebarLayout(self: *AttachedClient, change: data.SidebarLayout) !void {
    if (self.model.sidebar_visible != change.visible or self.model.sidebar_width != change.width or
        self.model.version().chrome != change.chrome_revision)
    {
        return error.StaleSidebarLayout;
    }

    self.model.to_host.invalidate_placements = true;
    const active = self.model.tabs.activeSlot() orelse return;
    try self.resizeAttachedPanes(active, self.geometry().area);
}

/// Delivers one synthetic key sequence in a single pane-input transaction.
fn sendPaneKeys(self: *AttachedClient, target: data.PaneInputTarget, keys: []const data.Key) !?data.PaneInputDelivery {
    const started = core.now(self.io);

    if (keys.len == 0 or keys.len > data.input_limits.max_synthetic_keys) {
        return error.InvalidInputLength;
    }

    const plan = self.model.planPaneInput(target) orelse return null;
    var encoded: [data.input_limits.max_encoded_bytes]u8 = undefined;
    var len: usize = 0;
    for (keys) |key| {
        var key_bytes: [32]u8 = undefined;
        const bytes = try encoding_support.encodeKey(
            &key_bytes,
            key,
            plan.input_modes,
        );
        if (bytes.len > encoded.len - len) {
            return error.InvalidInputLength;
        }

        @memcpy(encoded[len..][0..bytes.len], bytes);
        len += bytes.len;
    }

    return self.recordPaneInput(started, try self.deliverPaneInput(
        plan,
        .{
            .source = .host,
            .bytes = encoded[0..len],
        },
    ));
}

/// Encodes one Lua paste decision against the current child modes.
fn pasteExpression(self: *AttachedClient, text: []const u8) !?data.PaneInputDelivery {
    const started = core.now(self.io);

    const plan = self.model.planPaneInput(.focused) orelse return null;
    const framing_bytes: usize = if (plan.input_modes.bracketed_paste) 12 else 0;
    if (text.len > data.input_limits.max_encoded_bytes - framing_bytes) {
        return error.InvalidInputLength;
    }

    var encoded: [data.input_limits.max_encoded_bytes]u8 = undefined;
    const bytes = try encoding_support.encodePaste(
        &encoded,
        text,
        plan.input_modes,
    );

    return self.recordPaneInput(started, try self.deliverPaneInput(
        plan,
        .{
            .source = .paste,
            .bytes = bytes,
        },
    ));
}

/// Delivers one history command, with execution outside bracketed paste framing.
/// Example: `_ = try historyPaste(client, .{ .text = command, .run = false });`.
fn pasteHistoryCommand(self: *AttachedClient, text: []const u8, run: bool) !?data.PaneInputDelivery {
    const started = core.now(self.io);

    const plan = self.model.planPaneInput(.focused) orelse return null;
    try pane_input_module.validateHistoryText(text, plan.input_modes.bracketed_paste);
    var encoded: [core.max_history_command_bytes + 13]u8 = undefined;
    const paste = try encoding_support.encodePaste(
        &encoded,
        text,
        plan.input_modes,
    );
    var len = paste.len;
    if (run) {
        encoded[len] = '\r';
        len += 1;
    }

    return self.recordPaneInput(started, try self.deliverPaneInput(
        plan,
        .{
            .source = .paste,
            .bytes = encoded[0..len],
            .limit = encoded.len,
        },
    ));
}

/// Delivers one explicit marker for an exact model-owned paste session.
fn sendPasteMarker(self: *AttachedClient, session: data.PanePasteSession, boundary: data.PanePasteBoundary) !?data.PaneInputDelivery {
    const started = core.now(self.io);

    const plan = self.model.planPaneInput(
        .{
            .paste_session = session,
        },
    ) orelse return null;

    const bytes = switch (boundary) {
        .start => "\x1b[200~",
        .finish => "\x1b[201~",
    };

    return self.recordPaneInput(started, try self.deliverPaneInput(
        plan,
        .{
            .source = .paste,
            .bytes = bytes,
        },
    ));
}

fn recordPaneInput(self: *AttachedClient, started: u64, delivery: ?data.PaneInputDelivery) ?data.PaneInputDelivery {
    const completed = delivery orelse return null;

    if (completed.byte_count != 0) {
        self.model.to_host.pane_input = .{
            .pane_id = completed.pane_id,
            .at_ns = core.monotonic(self.io),
        };
    }

    if (comptime core.enabled) {
        if (completed.source != .mouse) {
            self.telemetry.metrics.input_events += 1;
            self.telemetry.metrics.input_bytes += completed.byte_count;
            self.telemetry.metrics.input_enqueue.observe(core.elapsed(started, core.now(self.io)));
        }
    }

    return completed;
}

fn deliverPaneInput(self: *AttachedClient, plan: data.PaneInputPlan, prepared: data.PreparedPaneInput) !data.PaneInputDelivery {
    if (prepared.bytes.len == 0 or prepared.bytes.len > prepared.limit) {
        return error.InvalidInputLength;
    }

    if (prepared.source != .mouse) {
        _ = self.model.clearPointerSelection();
    }

    if (prepared.source != .mouse and prepared.restore_viewport) {
        _ = try self.applyPaneViewport(
            .{
                .pane_id = plan.pane_id,
                .target = .bottom,
            },
        );
    }

    try self.sendRuntimeInput(
        .{
            .pane_id = plan.pane_id,
            .bytes = prepared.bytes,
        },
    );

    return .{
        .pane_id = plan.pane_id,
        .byte_count = prepared.bytes.len,
        .source = prepared.source,
    };
}

fn deliverPanePaste(self: *AttachedClient, delivery: data.PanePasteDelivery) !bool {
    const result = switch (delivery) {
        .marker => |marker| try self.sendPasteMarker(marker.session, marker.boundary),
        .content => |content_delivery| try self.sendPaneInput(
            .{
                .target = .{
                    .paste_session = content_delivery.session,
                },
                .source = .paste,
                .payload = .{
                    .bytes = content_delivery.text,
                },
            },
        ),
    };

    return result != null;
}

fn applyPaneMouseEffect(self: *AttachedClient, effect: data.PaneMouseEffect) !void {
    switch (effect) {
        .selection => |selection| {
            _ = self.model.beginPointerSelection(
                .{
                    .pane_id = selection.plan.pane_id,
                    .position = .{
                        .x = selection.command.event.x - selection.plan.content.x,
                        .y = selection.command.event.y - selection.plan.content.y,
                    },
                    .now_ns = core.monotonic(self.io),
                },
            );
        },
        .viewport => |scroll| {
            _ = try self.applyPaneViewport(
                .{
                    .pane_id = scroll.pane_id,
                    .target = .{
                        .relative = scroll.delta,
                    },
                },
            );
        },
        .alternate_scroll => |scroll| {
            std.debug.assert(scroll.delta != 0);
            const bytes = if (scroll.delta < 0) "\x1b[A" else "\x1b[B";
            for (0..@abs(scroll.delta)) |_| {
                _ = try self.sendPaneInput(
                    .{
                        .target = .{
                            .pane = scroll.pane_id,
                        },
                        .source = .mouse,
                        .payload = .{
                            .bytes = bytes,
                        },
                    },
                );
            }
        },
        .report => |report| {
            try self.deliverPaneMouseReport(report, false);
        },
    }
}

fn deliverPaneMouseReport(self: *AttachedClient, report: data.ReportEffect, retained: bool) !void {
    var encoded: [64]u8 = undefined;
    const bytes = try pane_mouse_input.encodeReport(&encoded, report);
    _ = try self.sendPaneInput(
        .{
            .target = if (retained) .{
                .pointer_lease = report.plan.pane_id,
            } else .{
                .pane = report.plan.pane_id,
            },
            .source = .mouse,
            .payload = .{
                .bytes = bytes,
            },
        },
    );
}

fn routePromptInput(self: *AttachedClient, command: data.KeyRoutingCommand) !void {
    switch (command) {
        .key => |value| _ = try self.inputPrompt(
            .{
                .key = value,
            },
        ),
        .bytes => |bytes| try self.host_input_source.routePromptBytes(bytes),
    }
}

fn routePaneKey(self: *AttachedClient, command: data.PaneCommand) !?core.PaneId {
    const delivery = try self.sendPaneInput(
        .{
            .target = switch (command.target) {
                .current => .focused,
                .lease => |pane_id| .{
                    .key_lease = pane_id,
                },
            },
            .source = .host,
            .payload = switch (command.input) {
                .bytes => |bytes| .{
                    .bytes = bytes,
                },
                .key => |key| .{
                    .key = key,
                },
            },
        },
    );

    const completed = delivery orelse return null;
    if (self.observeAttachmentInput(completed.pane_id, command.input)) {
        self.model.to_host.invalidate_placements = true;
        if (self.model.tabs.activeSlot()) |tab| {
            try self.resizeAttachedPanes(tab, self.geometry().area);
        }
    }

    return completed.pane_id;
}

fn routePhysicalKey(self: *AttachedClient, key: data.Key, authority: data.KeyRoutingAuthority) !data.KeyRoutingOutcome {
    const identity = key.physical orelse return (try self.routeCurrentKey(
        .{
            .key = key,
        },
        authority,
    )).outcome;

    return switch (key.phase) {
        .press => self.routeKeyPress(key, authority),
        .repeat => self.routeKeyRepeat(key, self.model.input_leases.owner(identity) orelse return .{
            .owner = .ignored,
        }),
        .release => self.routeKeyRelease(key, self.model.input_leases.release(identity) orelse return .{
            .owner = .ignored,
        }),
    };
}

fn routeKeyPress(self: *AttachedClient, key: data.Key, authority: data.KeyRoutingAuthority) !data.KeyRoutingOutcome {
    const identity = key.physical.?;
    if (!self.model.input_leases.acquire(identity, .ignored)) {
        return .{
            .owner = .ignored,
            .lease_overflow = true,
        };
    }
    errdefer _ = self.model.input_leases.release(identity);

    const routed = try self.routeCurrentKey(
        .{
            .key = key,
        },
        authority,
    );
    const assigned = self.model.input_leases.acquire(identity, routed.lease_owner);
    std.debug.assert(assigned);

    return routed.outcome;
}

fn routeKeyRepeat(self: *AttachedClient, key: data.Key, owner: data.KeyRoutingLeaseOwner) !data.KeyRoutingOutcome {
    return switch (owner) {
        .ignored => .{
            .owner = .ignored,
        },
        .attachment_modal => .{
            .owner = .attachment_modal,
        },
        .name_prompt => prompt: {
            try self.routePromptInput(
                .{
                    .key = key,
                },
            );

            break :prompt .{
                .owner = .name_prompt,
            };
        },
        .copy_mode => copy: {
            _ = try self.applyCopyMode(
                .{
                    .key = key,
                },
            );

            break :copy .{
                .owner = .copy_mode,
            };
        },
        .pane => |pane_id| self.routeLeasedPaneKey(key, pane_id),
    };
}

fn routeKeyRelease(self: *AttachedClient, key: data.Key, owner: data.KeyRoutingLeaseOwner) !data.KeyRoutingOutcome {
    return switch (owner) {
        .ignored => .{
            .owner = .ignored,
        },
        .attachment_modal => .{
            .owner = .attachment_modal,
        },
        .name_prompt => .{
            .owner = .name_prompt,
        },
        .copy_mode => .{
            .owner = .copy_mode,
        },
        .pane => |pane_id| self.routeLeasedPaneKey(key, pane_id),
    };
}

fn routeCurrentKey(self: *AttachedClient, command: data.KeyRoutingCommand, authority: data.KeyRoutingAuthority) !data.Routed {
    switch (command) {
        .bytes => {},
        .key => |key| {
            if (authority.attachment_modal_active) {
                if (key.code == .escape) {
                    _ = self.attachment_shelf.closeModal();
                }

                return .{
                    .outcome = .{
                        .owner = .attachment_modal,
                    },
                    .lease_owner = .attachment_modal,
                };
            }
        },
    }

    if (authority.prompt_active) {
        try self.routePromptInput(command);

        return .{
            .outcome = .{
                .owner = .name_prompt,
            },
            .lease_owner = .name_prompt,
        };
    }

    if (authority.copy_mode_active) {
        switch (command) {
            .bytes => {},
            .key => |key| _ = try self.applyCopyMode(
                .{
                    .key = key,
                },
            ),
        }

        return .{
            .outcome = .{
                .owner = .copy_mode,
            },
            .lease_owner = .copy_mode,
        };
    }

    const pane_id = try self.routePaneKey(
        .{
            .target = .current,
            .input = command,
        },
    );
    if (pane_id != null and data.key_routing.requestsClipboardPreview(command)) {
        _ = self.startClipboardCapture() catch {};
    }

    return .{
        .outcome = .{
            .owner = .pane,
            .delivered = pane_id != null,
        },
        .lease_owner = if (pane_id) |id| .{
            .pane = id,
        } else .ignored,
    };
}

fn routeLeasedPaneKey(self: *AttachedClient, key: data.Key, pane_id: core.PaneId) !data.KeyRoutingOutcome {
    const delivered = try self.routePaneKey(
        .{
            .target = .{
                .lease = pane_id,
            },
            .input = .{
                .key = key,
            },
        },
    );

    return .{
        .owner = .pane,
        .delivered = delivered != null,
    };
}

/// Starts workspace creation only when the current client can plan the
/// request.
fn beginWorkspacePrompt(self: *AttachedClient) bool {
    if (!self.openNamePrompt(.create_workspace)) {
        return false;
    }

    self.openPathCompletion() catch {};
    return true;
}

/// Length and head of the directory field, enough to notice a text change
/// without copying up to `max_cwd_bytes` per keystroke.
fn promptDirectoryVersion(prompt_state: *const data.NamePromptState) ?[2]usize {
    const prompt = prompt_state.currentConst() orelse return null;
    if (prompt.form() == null) {
        return null;
    }

    return .{
        prompt.directory.len,
        std.hash.Crc32.hash(prompt.directory.text()),
    };
}

fn promptListSnapshot(prompt_state: *const data.NamePromptState) data.PromptListSnapshot {
    const prompt = prompt_state.currentConst() orelse return .{};
    var snapshot: data.PromptListSnapshot = switch (prompt.target()) {
        .goto => .{
            .kind = .goto,
        },
        .history => .{
            .kind = .history,
        },
        .suggest => .{
            .kind = .suggest,
        },
        .palette => switch (prompt.paletteMode()) {
            .goto => .{
                .kind = .goto,
            },
            .suggest => .{
                .kind = .suggest,
            },
            .actions => .{
                .kind = .actions,
            },
        },
        else => return .{},
    };

    snapshot.selection = prompt.selection();
    snapshot.scope = prompt.scope();
    const text = prompt.paletteQuery();
    snapshot.len = @intCast(text.len);
    @memcpy(snapshot.text[0..text.len], text);
    return snapshot;
}

/// Applies the accepted list submission after the prompt closed. Pastes and
/// navigation are gated on prompt authority (`planPaneInput`, handoffs), so
/// they must not run inside the submit effect while the prompt is active.
fn finishPromptList(self: *AttachedClient, before: data.PromptListSnapshot) !void {
    switch (before.kind) {
        .none => {},
        .history => try self.pasteHistorySelection(
            .{
                .selection = before.selection,
                .run = self.model.config.history_enter_runs != before.alternate,
            },
        ),
        .suggest => try self.pasteSuggestion(),
        .goto => {
            var results: data.Results = .{};
            data.goto_picker.collect(
                pickerSources(&self.model),
                before.textSlice(),
                &results,
            );
            if (results.len == 0) {
                return;
            }

            const index = @min(before.selection, @as(u16, results.len) - 1);
            try self.navigatePickerItem(results.slice()[index].item);
        },
        .actions => {
            var results: data.CommandResults = .{};
            data.command_palette.collect(before.textSlice(), &results);
            if (results.len == 0) {
                return;
            }

            const index = @min(before.selection, @as(u16, results.len) - 1);
            _ = try self.executeAction(data.command_palette.entries[results.slice()[index].index].action, .effect);
        },
    }
}

/// Requeries the runtime only when the palette's query text actually
/// changed, so selection moves and pastes stay local.
fn refreshPromptHistory(self: *AttachedClient, before: data.PromptListSnapshot) !void {
    const prompt = self.model.name_prompt.currentConst() orelse return;
    if (prompt.target() != .history) {
        return;
    }

    const text = prompt.field.text();
    if (before.kind == .history and before.scope == prompt.scope() and
        std.mem.eql(
            u8,
            before.textSlice(),
            text,
        ))
    {
        return;
    }

    try self.queryHistory(text);
}

/// Drops a landed or pending suggestion once its request text changed, so
/// the next Enter asks again instead of pasting a stale answer. Entering
/// the palette's `?` mode from another mode counts as a change.
fn discardEditedSuggestion(self: *AttachedClient, before: data.PromptListSnapshot) void {
    const prompt = self.model.name_prompt.currentConst() orelse return;
    if (promptListSnapshot(&self.model.name_prompt).kind != .suggest) {
        return;
    }

    if (before.kind == .suggest and std.mem.eql(
        u8,
        before.textSlice(),
        prompt.paletteQuery(),
    )) {
        return;
    }

    self.model.suggestion.invalidate();
}

/// Keeps the picker selection inside the deterministic result set the
/// renderer and the submit path both derive from the current query.
fn constrainPickerSelection(self: *AttachedClient) void {
    const prompt = self.model.name_prompt.currentConst() orelse return;
    if (prompt.selection() == 0) {
        return;
    }

    const count: u16 = switch (prompt.target()) {
        .goto => self.pickerCount(prompt.field.text()),
        .history => self.model.history_palette.len,
        .suggest => 1,
        .create_workspace => @intCast(self.model.path_completion.entries().len),
        .palette => switch (prompt.paletteMode()) {
            .goto => self.pickerCount(prompt.paletteQuery()),
            .suggest => 1,
            .actions => blk: {
                var results: data.CommandResults = .{};
                data.command_palette.collect(prompt.paletteQuery(), &results);
                break :blk results.len;
            },
        },
        else => return,
    };
    self.model.name_prompt.constrainSelection(count);
}

fn pickerCount(self: *AttachedClient, query: []const u8) u16 {
    var results: data.Results = .{};
    data.goto_picker.collect(
        pickerSources(&self.model),
        query,
        &results,
    );
    return results.len;
}

fn pickerSources(model: *const data.ClientModel) data.Sources {
    return .{
        .agents = &model.agent_snapshot,
        .workspaces = &model.workspace_list_snapshot,
        .model = model,
    };
}

fn navigatePickerItem(self: *AttachedClient, item: data.goto_picker.Item) !void {
    switch (item) {
        .workspace => |workspace| _ = try self.selectWorkspace(
            .{
                .workspace = workspace,
            },
        ),
        .tab => |tab_id| {
            _ = try self.selectTab(
                .{
                    .target = .{
                        .tab_id = tab_id,
                    },
                },
            );
        },
        .agent => |key| _ = try self.navigateAgent(key),
    }
}

fn submitPrompt(self: *AttachedClient, submission: data.Submission) !bool {
    return switch (submission.target) {
        .create_workspace => self.submitWorkspacePrompt(submission),
        .rename_workspace => |workspace| blk: {
            break :blk try self.requestWorkspaceRename(
                .{
                    .workspace = workspace,
                    .name = submission.name,
                },
            );
        },
        .rename_tab => |tab_id| blk: {
            break :blk try self.requestTabRename(
                .{
                    .tab_id = tab_id,
                    .label = submission.name,
                },
            );
        },
        // List targets only close here; the picked entry is applied by
        // `finishListSubmission` once the prompt no longer owns input.
        .history => blk: {
            const prompt = self.model.name_prompt.currentConst() orelse break :blk false;
            if (!self.canSubmitHistory(prompt.selection())) {
                break :blk false;
            }

            self.list_submission_alternate = submission.alternate;
            break :blk true;
        },
        .goto => blk: {
            self.list_submission_alternate = submission.alternate;
            break :blk true;
        },
        .suggest => self.submitSuggestion(submission.name),
        // The palette closes like the list its prefix selects; `>` closes
        // only when a catalogue entry matches, so Enter on no match is inert.
        .palette => blk: {
            const prompt = self.model.name_prompt.currentConst() orelse break :blk false;
            switch (prompt.paletteMode()) {
                .goto => {
                    self.list_submission_alternate = submission.alternate;
                    break :blk true;
                },
                .suggest => break :blk try self.submitSuggestion(prompt.paletteQuery()),
                .actions => {
                    var results: data.CommandResults = .{};
                    data.command_palette.collect(prompt.paletteQuery(), &results);
                    break :blk results.len != 0;
                },
            }
        },
        .copy_search => blk: {
            const pane_id = self.model.copyModeTarget() orelse break :blk true;
            const request_id = try self.model.request_lifecycle.nextId();
            var owned: data.OwnedSearch = .{
                .request_id = request_id,
                .pane_id = pane_id,
                .needle_len = @intCast(submission.name.len),
            };
            @memcpy(owned.needle[0..submission.name.len], submission.name);
            try self.sendRuntime(
                .{
                    .search_pane = owned,
                },
            );
            break :blk true;
        },
    };
}

/// Enter asks while no suggestion is ready and the prompt stays open; once
/// a suggestion landed, Enter closes and pastes it.
fn submitSuggestion(self: *AttachedClient, text: []const u8) !bool {
    if (self.model.suggestion.phase == .ready) {
        return true;
    }

    if (text.len == 0 or self.model.suggestion.phase == .waiting) {
        return false;
    }

    try self.requestSuggestion(text);
    return false;
}

/// Expands the typed directory, asks once before creating a missing one and
/// derives the context name from the directory when the name is empty.
fn submitWorkspacePrompt(self: *AttachedClient, submission: data.Submission) !bool {
    var buffer: [path_queries.max_path_bytes]u8 = undefined;
    const cwd: []const u8 = if (submission.directory.len == 0)
        ""
    else
        self.expandPromptDirectory(submission.directory, &buffer) catch return false;
    if (cwd.len != 0) {
        switch (self.promptDirectoryStatus(cwd)) {
            .directory => {},
            .other => return false,
            .missing => if (!submission.create_directory) {
                self.model.name_prompt.requestDirectoryConfirmation();
                return false;
            },
        }
    }

    const name = if (submission.name.len != 0) submission.name else path_expansion.basename(cwd);
    if (name.len == 0) {
        return false;
    }

    return self.requestWorkspaceCreation(
        .{
            .name = name,
            .cwd = cwd,
            .create_cwd = submission.create_directory and cwd.len != 0,
        },
    ) catch |err| switch (err) {
        error.InvalidWorkspaceName, error.InvalidUtf8 => false,
        else => err,
    };
}

fn applyPromptCommand(self: *AttachedClient, command: data.PromptCommand) !data.PromptOutcome {
    return switch (self.model.name_prompt.apply(command)) {
        .unchanged => .unchanged,
        .routing_changed => .routing_changed,
        .changed => .changed,
        .cancelled => .cancelled,
        .removed => .removed,
        .completion_requested => .completion_requested,
        .submitted => |submission| if (!try self.submitPrompt(submission))
            .blocked
        else blk: {
            std.debug.assert(self.model.name_prompt.finish(submission.target));
            break :blk .finished;
        },
    };
}

/// Mirrors one successfully delivered Backspace, Delete or Enter into the
/// preview collection owned by that pane.
fn observeAttachmentInput(self: *AttachedClient, pane_id: core.PaneId, command: data.KeyRoutingCommand) bool {
    self.expectMarkerDeletion(pane_id, command);
    const key = switch (command) {
        .bytes => return false,
        .key => |value| value,
    };
    if (key.phase == .release or key.mods.ctrl or key.mods.alt or key.mods.shift) {
        return false;
    }

    const target = self.attachment_catalog.visibleTarget() orelse
        self.model.focusedAttachmentTarget() orelse return false;
    if (target.pane_id != pane_id) {
        return false;
    }

    switch (key.code) {
        .enter => {
            if (self.attachmentPromptContinues(target)) {
                return false;
            }

            _ = self.model.clipboard.cancel(target);

            return self.attachment_shelf.removePrompt(target) orelse false;
        },
        .backspace, .delete => {
            const deletion: data.AttachmentMarkerDeletion = if (key.code == .backspace) .backward else .forward;
            const id = self.attachmentMarkerAtCursor(deletion);
            if (id == null) {
                if (self.pendingAttachmentMarkerAtCursor(deletion)) {
                    _ = self.model.clipboard.cancel(target);
                }

                return false;
            }

            return self.attachment_shelf.remove(id.?) orelse false;
        },
        else => return false,
    }
}

/// Resolves the marker policy of a target whose provider learns marker
/// identities from committed frames.
fn attachmentMarkerPolicy(self: *AttachedClient, target: data.AttachmentTarget) ?data.AttachmentMarkerPolicy {
    const markers = self.model.attachmentMarkers(target) orelse return null;
    const policy = attachment_prompt.markerPolicy(markers);

    return if (policy.learnsIdentity()) policy else null;
}

/// Reconciles learned attachment identities (Claude numbers, Pi paths)
/// after one pane frame.
fn reconcileAttachmentFrame(self: *AttachedClient, pane_id: core.PaneId) bool {
    const target = self.attachment_catalog.visibleTarget() orelse return false;
    if (target.pane_id != pane_id or self.attachmentMarkerPolicy(target) == null) {
        return false;
    }

    const pane = self.model.panes.findConst(pane_id) orelse return false;

    return self.attachment_shelf.reconcileMarkers(
        target,
        .{
            .buffer = &pane.buffer,
            .cursor = pane.cursor,
        },
    ) orelse false;
}

fn planAttachmentRemoval(self: *AttachedClient, id: data.AttachmentId) ?data.RemovalCommand {
    const target = self.attachment_catalog.visibleTarget() orelse return null;
    const model = self.model.tabs.activeSlot() orelse return null;
    const pane = self.model.panes.findInConst(self.model.tabs.location[model].tab_id, target.pane_id) orelse return null;
    const marker = self.attachment_catalog.planMarkerRemoval(
        id,
        .{
            .buffer = &pane.buffer,
            .cursor = pane.cursor,
        },
    ) orelse return null;

    return .{
        .pane_id = target.pane_id,
        .marker = marker,
    };
}

fn deliverAttachmentRemoval(self: *AttachedClient, command: data.RemovalCommand) !void {
    var keys: [data.attachment_types.max_removal_keys]data.Key = undefined;
    var len: usize = 0;
    const movement: data.Key.Code = switch (command.marker.direction) {
        .left => .left,
        .right => .right,
    };
    const restoration: data.Key.Code = switch (command.marker.direction) {
        .left => .right,
        .right => .left,
    };
    for (0..command.marker.steps) |_| {
        keys[len] = .{
            .code = movement,
        };
        len += 1;
    }

    for (0..command.marker.deletions) |_| {
        keys[len] = .{
            .code = switch (command.marker.deletion) {
                .backward => .backspace,
                .forward => .delete,
            },
        };
        len += 1;
    }

    for (0..command.marker.steps) |_| {
        keys[len] = .{
            .code = restoration,
        };
        len += 1;
    }

    _ = try self.sendPaneKeys(
        .{
            .pane = command.pane_id,
        },
        keys[0..len],
    ) orelse
        return error.AttachmentMarkerDeliveryUnavailable;
}

fn attachmentMarkerAtCursor(self: *AttachedClient, deletion: data.AttachmentMarkerDeletion) ?data.AttachmentId {
    const target = self.attachment_catalog.visibleTarget() orelse return null;
    const model = self.model.tabs.activeSlot() orelse return null;
    const pane = self.model.panes.findInConst(self.model.tabs.location[model].tab_id, target.pane_id) orelse return null;

    return self.attachment_catalog.idAtMarkerDeletion(
        .{
            .buffer = &pane.buffer,
            .cursor = pane.cursor,
        },
        deletion,
    );
}

fn pendingAttachmentMarkerAtCursor(self: *AttachedClient, deletion: data.AttachmentMarkerDeletion) bool {
    const target = self.model.focusedAttachmentTarget() orelse return false;
    const model = self.model.tabs.activeSlot() orelse return false;
    const pane = self.model.panes.findInConst(self.model.tabs.location[model].tab_id, target.pane_id) orelse return false;

    const markers = self.model.attachmentMarkers(target) orelse return false;

    return self.attachment_catalog.pendingMarkerAtDeletion(
        .{
            .buffer = &pane.buffer,
            .cursor = pane.cursor,
        },
        .{
            .deletion = deletion,
            .policy = attachment_prompt.markerPolicy(markers),
        },
    );
}

/// Reports whether the accepted Enter continues the prompt instead of
/// submitting it: the agent's editor treats a trailing backslash as a
/// newline request.
fn attachmentPromptContinues(self: *AttachedClient, target: data.AttachmentTarget) bool {
    const markers = self.model.attachmentMarkers(target) orelse return false;
    if (!attachment_prompt.backslashContinuesPrompt(attachment_prompt.markerPolicy(markers))) {
        return false;
    }

    const model = self.model.tabs.activeSlot() orelse return false;
    const pane = self.model.panes.findInConst(self.model.tabs.location[model].tab_id, target.pane_id) orelse return false;

    return markers_module.promptContinuesAtCursor(
        .{
            .buffer = &pane.buffer,
            .cursor = pane.cursor,
        },
    );
}

/// Adopts one validated generation through the client application boundary.
/// The client settings one configuration snapshot selects.
fn configFrom(snapshot: *const Snapshot) data.Config {
    return .{
        .notification_delivery = snapshot.notification_delivery,
        .history_show_agent_commands = snapshot.history_show_agent_commands,
        .history_enter_runs = snapshot.history_enter_runs,
        .history_match_fts = snapshot.history_match_fts,
        .themes = .{
            .light = snapshot.theme_light,
            .dark = snapshot.theme_dark,
        },
    };
}

fn adoptConfiguration(self: *AttachedClient, adoption: Adoption) !data.ConfigurationCommit {
    var consumed = false;
    errdefer if (!consumed) adoption.deinit(self.gpa);
    const snapshot = &adoption.generation.snapshot;
    const commit = try self.model.applyConfiguration(
        .{
            .generation = adoption.generation.number,
            .sidebar_visible = snapshot.sidebar_visible,
            .pane_gaps = snapshot.pane_gaps,
            .window_title = snapshot.windowTitle(),
            .bars = snapshot.bars.presentation(),
            .config = configFrom(snapshot),
        },
    );
    _ = self.model.clearDiagnostic();
    std.debug.assert(adoption.generation.number == commit.generation);
    const previous_generation = self.lua_generation;
    const previous_registry = self.plugin_registry;
    const previous_trust = self.trust_store;

    self.lua_generation = adoption.generation;
    self.plugin_registry = adoption.registry;
    self.trust_store = adoption.trust_store;
    self.model.to_host.rebind_input = true;
    self.model.config.sidebar_rendering = adoption.sidebar_rendering;
    self.model.sound_playback.configure(snapshot.sound);
    consumed = true;

    if (previous_generation) |generation| {
        generation.deinit();
    }
    if (previous_registry) |registry| {
        self.gpa.destroy(registry);
    }
    if (previous_trust) |trust| {
        self.gpa.destroy(trust);
    }
    if (commit.bars_changed) {
        try self.synchronizeBars();
    }
    if (!self.options.theme_locked) {
        self.model.theme = snapshot.resolveTheme(self.model.host.host_capabilities.appearance, null);
    }
    self.model.icon_theme = snapshot.icon_theme;
    if (commit.sidebar) |sidebar| {
        try self.deliverSidebarLayout(sidebar);
    } else if (commit.pane_gaps_changed) {
        self.model.to_host.invalidate_placements = true;
        if (self.model.tabs.activeSlot()) |tab| {
            try self.resizeAttachedPanes(tab, self.geometry().area);
        }
    }

    std.debug.assert(consumed);

    return commit;
}

/// Requests an unconditional load on the next normal worker cycle. Example: `try config_reloads.request(client);`
fn requestConfigReload(self: *AttachedClient) !void {
    if (self.options.config_path == null or self.options.trust_path == null or self.lua_generation == null or self.plugin_registry == null) {
        return error.ConfigurationNotLoaded;
    }

    self.reload.force_next = true;
}

/// Reads adopted values without executing Lua. Example: `try config_queries.show(client, reply);`
fn showConfiguration(self: *AttachedClient, reply: *core.ClientCommand) !void {
    const section = if (reply.length == 0) config_queries.Section.client else std.meta.stringToEnum(config_queries.Section, reply.text()) orelse return error.UnknownConfigurationSection;
    const generation = self.lua_generation orelse return error.ConfigurationNotLoaded;
    var writer = std.Io.Writer.fixed(&reply.bytes);
    if (section == .client) {
        try std.json.Stringify.value(
            .{
                .source = self.options.config_path,
                .profile = self.options.profile,
                .generation = self.model.configuration_generation,
                .sidebar_visible = self.model.sidebar_visible,
                .sidebar_width = self.model.sidebar_width,
                .workspace_list_collapsed = self.model.workspace_list_collapsed,
                .pane_gaps = self.model.pane_gaps,
                .window_title = self.model.windowTitleTemplate(),
                .sound = generation.snapshot.sound,
                .notification_delivery = generation.snapshot.notification_delivery,
                .history_show_agent_commands = generation.snapshot.history_show_agent_commands,
                .history_enter_runs = generation.snapshot.history_enter_runs,
                .history_match_fts = generation.snapshot.history_match_fts,
                .sections = [_][]const u8{
                    "client",
                    "theme",
                    "gui",
                    "input",
                    "runtime",
                    "binding",
                },
            },
            .{},
            &writer,
        );
    } else {
        try config_queries.writeSection(
            &generation.snapshot,
            .{
                .section = section,
                .index = std.math.cast(usize, reply.value) orelse return error.InvalidIndex,
            },
            &writer,
        );
    }

    reply.length = @intCast(writer.buffered().len);
    reply.status = .applied;
}

/// Reads one bounded catalog page from the adopted generation. Example: `try plugin_queries.list(client, reply);`
fn listPlugins(self: *AttachedClient, reply: *core.ClientCommand) !void {
    const generation = self.lua_generation orelse return error.ConfigurationNotLoaded;
    if (reply.target_id != 0 and reply.target_id != generation.number) {
        return error.StaleConfiguration;
    }

    const registry = self.plugin_registry orelse return error.PluginRegistryUnavailable;
    const catalog: ConfiguredPlugins = .{
        .snapshot = &generation.snapshot,
        .registry = registry,
    };
    const index = std.math.cast(usize, reply.value) orelse return error.InvalidPage;
    const count = generation.snapshot.plugin_count;
    if (index > count) {
        return error.InvalidPage;
    }

    var writer = std.Io.Writer.fixed(&reply.bytes);
    try writer.print(
        "{{\"generation\":{d},\"entries\":[",
        .{
            generation.number,
        },
    );
    if (index < count) {
        const spec = &generation.snapshot.plugins[index];
        const package = catalog.package(index);
        try std.json.Stringify.value(
            .{
                .index = index,
                .path = spec.path(),
                .id = if (package) |loaded| loaded.manifest.id() else null,
                .version = if (package) |loaded| loaded.manifest.version() else null,
                .requested_enabled = self.reload.plugin_overrides.requested(spec.path()) orelse spec.enabled,
                .enabled = spec.enabled,
            },
            .{},
            &writer,
        );
    }

    try writer.writeAll("]}");
    reply.length = @intCast(writer.buffered().len);
    reply.value = if (index + 1 < count) @intCast(index + 1) else -1;
    reply.status = .applied;
}

/// Reads manifest metadata followed by individual action names. Example: `try plugin_queries.get(client, reply);`
fn describePlugin(self: *AttachedClient, reply: *core.ClientCommand) !void {
    const generation = self.lua_generation orelse return error.ConfigurationNotLoaded;
    if (reply.target_id != 0 and reply.target_id != generation.number) {
        return error.StaleConfiguration;
    }

    const registry = self.plugin_registry orelse return error.PluginRegistryUnavailable;
    const catalog: ConfiguredPlugins = .{
        .snapshot = &generation.snapshot,
        .registry = registry,
    };
    const index = try catalog.find(reply.text());
    const spec = &generation.snapshot.plugins[index];
    const package = catalog.package(index);
    const page = std.math.cast(usize, reply.value) orelse return error.InvalidPage;
    const action_count: usize = if (package) |loaded| loaded.manifest.action_count else 0;
    if (page > action_count) {
        return error.InvalidPage;
    }

    var writer = std.Io.Writer.fixed(&reply.bytes);
    try writer.print(
        "{{\"generation\":{d},\"entries\":[",
        .{
            generation.number,
        },
    );
    if (page == 0) {
        if (package) |loaded| {
            var capabilities: [std.meta.fields(core.Capability).len][]const u8 = undefined;
            var count: usize = 0;
            var iterator = loaded.manifest.capabilities.iterator();
            while (iterator.next()) |capability| {
                capabilities[count] = capability.canonicalName();
                count += 1;
            }

            const digest = std.fmt.bytesToHex(loaded.digest, .lower);
            try std.json.Stringify.value(
                .{
                    .path = spec.path(),
                    .requested_enabled = self.reload.plugin_overrides.requested(spec.path()) orelse spec.enabled,
                    .enabled = spec.enabled,
                    .id = loaded.manifest.id(),
                    .version = loaded.manifest.version(),
                    .entry = loaded.manifest.entry(),
                    .source = loaded.manifest.source(),
                    .revision = loaded.manifest.revision(),
                    .digest = digest[0..],
                    .capabilities = capabilities[0..count],
                },
                .{},
                &writer,
            );
        } else {
            try std.json.Stringify.value(
                .{
                    .path = spec.path(),
                    .requested_enabled = self.reload.plugin_overrides.requested(spec.path()) orelse spec.enabled,
                    .enabled = spec.enabled,
                    .id = @as(?[]const u8, null),
                },
                .{},
                &writer,
            );
        }
    } else {
        try std.json.Stringify.value(
            package.?.manifest.actions[page - 1].slice(),
            .{},
            &writer,
        );
    }

    try writer.writeAll("]}");
    reply.length = @intCast(writer.buffered().len);
    reply.value = if (page < action_count) @intCast(page + 1) else -1;
    reply.status = .applied;
}

fn setPluginEnabled(self: *AttachedClient, reply: *core.ClientCommand, enabled: bool) !void {
    const generation = self.lua_generation orelse return error.ConfigurationNotLoaded;
    const registry = self.plugin_registry orelse return error.PluginRegistryUnavailable;
    if (self.options.config_path == null or self.options.trust_path == null) {
        return error.ConfigurationNotLoaded;
    }

    const catalog: ConfiguredPlugins = .{
        .snapshot = &generation.snapshot,
        .registry = registry,
    };
    const index = try catalog.find(reply.text());
    var override: data.PluginOverride = .{
        .spec = generation.snapshot.plugins[index],
    };
    override.spec.enabled = enabled;
    if (catalog.package(index)) |package| {
        override.plugin_id = core.stableId(package.manifest.id());
    }

    try self.reload.plugin_overrides.set(override);
    self.reload.force_next = true;
    reply.status = .admitted;
}

/// Schedules an existing declared action with normal capability checks. Example: `try plugin_invocations.run(client, reply);`
fn runPluginCommand(self: *AttachedClient, reply: *core.ClientCommand) !void {
    const generation = self.lua_generation orelse return error.ConfigurationNotLoaded;
    const registry = self.plugin_registry orelse return error.PluginRegistryUnavailable;
    const catalog: ConfiguredPlugins = .{
        .snapshot = &generation.snapshot,
        .registry = registry,
    };
    const index = try catalog.find(reply.text());
    const package = catalog.package(index) orelse return error.PluginDisabled;
    const requested: data.PluginAction = .{
        .plugin = core.stableId(package.manifest.id()),
        .action = reply.target_id,
    };
    _ = try registry.resolve(requested);
    switch (try self.startPluginAction(requested, self.model.callbackContext())) {
        .started => reply.status = .admitted,
        .busy => return error.PluginWorkerBusy,
        .unavailable => return error.PluginWorkerUnavailable,
        .rejected => |err| return err,
    }
}

/// Resolves one configured action and schedules its work outside the input path.
fn startPluginAction(self: *AttachedClient, requested: data.PluginAction, callback_context: data.CallbackContext) !plugin_action.StartOutcome {
    if (self.model.plugins.pluginExecution() != null) {
        return self.reportPluginStart(.busy);
    }

    const registry = self.plugin_registry orelse return self.reportPluginStart(.unavailable);
    const invocation = registry.resolve(requested) catch |err| switch (err) {
        error.PluginNotConfigured, error.UnknownPluginAction => return self.reportPluginStart(
            .{
                .rejected = err,
            },
        ),
    };
    const request = registry.workerRequest(invocation, callback_context) catch |err| switch (err) {
        error.PluginNotConfigured, error.UnknownPluginAction => return self.reportPluginStart(
            .{
                .rejected = err,
            },
        ),
    };
    const execution = (try self.model.beginPluginExecution()) orelse
        return self.reportPluginStart(.busy);
    {
        errdefer {
            const rolled_back = self.model.plugins.finishPluginExecution(execution.id);
            std.debug.assert(rolled_back != null);
        }

        try self.workers.start(.{ .plugin = .{
            .execution_id = execution.id,
            .request = request,
        } });
    }

    return self.reportPluginStart(
        .{
            .started = execution,
        },
    );
}

fn reportPluginStart(self: *AttachedClient, outcome: plugin_action.StartOutcome) !plugin_action.StartOutcome {
    if (plugin_action_delivery.startFailurePublication(outcome)) |failure| {
        try self.publishPluginFailure(failure);
    }
    return outcome;
}

fn authorizePluginResult(active_registry: ?*Registry, result: data.PluginResult) !void {
    const registry = active_registry orelse return error.PluginRegistryUnavailable;

    try registry.authorizeBatch(
        .{
            .package_index = result.package_index,
            .plugin_id = result.plugin_id,
            .digest = result.digest,
            .batch = result.batch,
        },
    );
}

fn applyPluginBatch(self: *AttachedClient, batch: *const data.EffectBatch) !plugin_action.BatchDisposition {
    for (batch.slice()) |effect| {
        if (try self.executeAction(effect, .effect) == .stop) {
            return .exit_client;
        }
    }

    return .continue_client;
}

fn reportPluginCompletion(self: *AttachedClient, outcome: plugin_action.CompletionOutcome) !bool {
    if (plugin_action_delivery.completionFailurePublication(outcome)) |failure| {
        try self.publishPluginFailure(failure);
    }
    return outcome == .exit;
}

fn publishPluginFailure(self: *AttachedClient, failure: data.FailurePublication) !void {
    _ = try client_diagnostic.replace(
        &self.model,
        .{
            .diagnostic = failure.diagnostic,
        },
    );
    try self.publishNotificationNow(
        .{
            .level = .failure,
            .title = failure.title,
            .message = self.model.diagnostic() orelse return error.ClientDiagnosticMissing,
            .duration_ns = 7 * std.time.ns_per_s,
        },
    );
}

/// Evaluates one configured Lua action against a model value snapshot.
fn evaluateLuaAction(self: *AttachedClient, command: data.LuaActionCommand) !data.LuaActionOutcome {
    var diagnostic: data.Diagnostic = .{};
    const callback_context = self.model.callbackContext();
    const generation = self.lua_generation orelse return .unavailable;

    const invocation: data.LuaInvocation = switch (command) {
        .callback => |reference| if (generation.invokeCallback(
            .{
                .reference = reference,
                .context = callback_context,
            },
            &diagnostic,
        )) |batch|
            .{
                .callback = batch,
            }
        else |err|
            lua_diagnostics.invocationFailure(&diagnostic, err),
        .expression => |reference| if (generation.invokeExpression(
            .{
                .reference = reference,
                .context = callback_context,
            },
            &diagnostic,
        )) |decision|
            .{
                .expression = decision,
            }
        else |err|
            lua_diagnostics.invocationFailure(&diagnostic, err),
    };

    return switch (invocation) {
        .unavailable => .unavailable,
        .failed => |failure| failed: {
            try self.publishLuaFailure(failure);
            break :failed .{
                .invocation_failed = failure.reason,
            };
        },
        .expression => |decision| expression: {
            _ = self.model.clearDiagnostic();
            break :expression .{
                .input = decision,
            };
        },
        .callback => |batch| callback: {
            switch (lua_diagnostics.validateBatch(
                self.plugin_registry,
                &batch,
                &diagnostic,
            )) {
                .valid => {},
                .failed => |failure| {
                    try self.publishLuaFailure(failure);
                    break :callback .{
                        .validation_failed = failure.reason,
                    };
                },
            }

            _ = self.model.clearDiagnostic();
            for (batch.slice()) |effect| {
                if (try self.applyLuaEffect(effect) == .exit_client) {
                    break :callback .exit;
                }
            }

            break :callback .applied;
        },
    };
}

fn applyLuaEffect(self: *AttachedClient, effect: data.Action) !data.LuaDisposition {
    return switch (effect) {
        .plugin => |requested| plugin: {
            _ = try self.startPluginAction(requested, self.model.callbackContext());
            break :plugin .continue_client;
        },
        .lua_callback, .lua_expr => error.InvalidCallbackResult,
        else => switch (try self.executeAction(effect, .effect)) {
            .continue_routing => .continue_client,
            .stop => .exit_client,
        },
    };
}

fn publishLuaFailure(self: *AttachedClient, failure: data.Failure) !void {
    _ = try client_diagnostic.replace(
        &self.model,
        .{
            .diagnostic = failure.diagnostic,
            .invalid_fallback = client_diagnostic.formatted(
                "Lua action failed: {s}",
                .{
                    @errorName(failure.reason),
                },
            ),
        },
    );
}

/// Starts the completion list when the form opens.
fn openPathCompletion(self: *AttachedClient) !void {
    self.model.path_completion.begin();
    try self.refreshPathCompletion();
}

/// Relists after the directory text changed. The expanded query is compared
/// with the wanted one, so selection moves and name edits start nothing.
fn refreshPathCompletion(self: *AttachedClient) !void {
    const prompt = self.model.name_prompt.currentConst() orelse return;
    if (prompt.form() == null) {
        return;
    }

    var buffer: [path_expansion.max_path_bytes]u8 = undefined;
    const text = prompt.directory.text();
    const expanded = self.expandPromptDirectory(text, &buffer) catch {
        self.model.path_completion.invalidate();
        self.model.path_completion.forgetQuery();
        return;
    };
    const query = path_queries.listingQuery(
        text,
        expanded,
        &buffer,
    );
    if (!self.model.path_completion.want(query)) {
        return;
    }
    if (self.model.path_completion.matches(query)) {
        return;
    }

    try self.startPathCompletion();
}

/// Replaces the directory text with the selected completion when the list
/// describes the current query; the field keeps its text otherwise.
fn acceptPathCompletion(self: *AttachedClient) !void {
    const prompt = self.model.name_prompt.currentConst() orelse return;
    const entries = self.model.path_completion.entries();
    if (entries.len == 0 or !self.model.path_completion.matches(self.model.path_completion.wantedSlice())) {
        return;
    }

    const index = @min(prompt.selection(), entries.len - 1);
    var buffer: [path_expansion.max_path_bytes]u8 = undefined;
    const path = self.model.path_completion.result.join(index, &buffer);
    if (path.len + 1 > path_expansion.max_path_bytes) {
        return;
    }

    buffer[path.len] = '/';
    self.model.name_prompt.replaceDirectory(buffer[0 .. path.len + 1]);
    try self.refreshPathCompletion();
}

/// Forgets the list when the form closes. A running listing completes into
/// nothing.
fn closePathCompletion(self: *AttachedClient) void {
    self.model.path_completion.begin();
}

/// Expands the typed directory against the focused pane's cwd.
fn expandPromptDirectory(self: *const AttachedClient, text: []const u8, buffer: *[path_expansion.max_path_bytes]u8) ![]const u8 {
    return path_expansion.expand(
        .{
            .text = text,
            .environ = self.options.environ,
            .base = focusedPaneCwd(&self.model),
        },
        buffer,
    );
}

/// One `stat` on submit, so a missing directory can ask for confirmation
/// before any request leaves the client.
fn promptDirectoryStatus(self: *const AttachedClient, path: []const u8) path_queries.DirectoryStatus {
    const stat = std.Io.Dir.cwd().statFile(
        self.io,
        path,
        .{},
    ) catch return .missing;
    return if (stat.kind == .directory) .directory else .other;
}

fn startPathCompletion(self: *AttachedClient) !void {
    const completion_state = &self.model.path_completion;
    if (completion_state.pending != .none or completion_state.wanted_len == 0) {
        return;
    }

    const id = completion_state.reserve();
    self.workers.start(.{ .path_completion = .init(id, completion_state.inflightSlice()) }) catch |err| {
        completion_state.pending = .none;
        return err;
    };
}

fn focusedPaneCwd(model: *const data.ClientModel) []const u8 {
    const active = model.tabs.activeSlot() orelse return "";
    const pane = data.tab_layout.focusedPaneConst(model, active) orelse return "";
    return pane.cwdSlice();
}

/// Resolves the current target and schedules one best-effort media capture.
fn startClipboardCapture(self: *AttachedClient) !clipboard_image.StartOutcome {
    if (!self.model.host.clipboard_capture) {
        return .unsupported;
    }

    const target = self.model.focusedAttachmentTarget() orelse return .no_target;
    const capture = (try self.model.clipboard.reserve(target)) orelse return .busy;
    errdefer {
        const rolled_back = self.model.clipboard.finish(capture.id);
        std.debug.assert(rolled_back != null);
    }

    try self.scheduleClipboardCapture(capture);
    return .{
        .started = capture,
    };
}

fn scheduleClipboardCapture(self: *AttachedClient, capture: data.ClipboardCapture) !void {
    const request: data.CaptureRequest = .{
        .target = capture.target,
        .sequence = @intFromEnum(capture.id),
        .marker_policy = if (self.model.attachmentMarkers(capture.target)) |markers|
            attachment_prompt.markerPolicy(markers)
        else
            .ordered,
    };

    try self.model.to_host.push(.{ .capture = request });
}

fn adoptClipboardCapture(self: *AttachedClient, capture: *data.Capture) !bool {
    const request = capture.request;
    var layout_changed = try self.attachment_shelf.adopt(capture);
    if (request.marker_policy.learnsIdentity()) {
        if (self.model.panes.findConst(request.target.pane_id)) |value| {
            layout_changed = layout_changed or (self.attachment_shelf.reconcileMarkers(
                request.target,
                .{
                    .buffer = &value.buffer,
                    .cursor = value.cursor,
                },
            ) orelse false);
        }
    }

    return layout_changed;
}

fn reportClipboardCapture(self: *AttachedClient, outcome: clipboard_image.CompletionOutcome) !void {
    const input: data.NotificationInput = switch (outcome) {
        .applied, .stale, .ignored, .no_image => return,
        .too_large => .{
            .level = .failure,
            .title = "Image preview skipped",
            .message = "The clipboard image exceeds Telar's local preview limit",
        },
        .worker_failed, .adoption_failed => |err| .{
            .level = .failure,
            .title = "Image preview failed",
            .message = @errorName(err),
        },
    };

    try self.publishNotificationNow(input);
}

/// Validates one request and retains its correlation before delivery. Example: `_ = try request(client, command);`
fn requestWorkspaceRename(self: *AttachedClient, command: data.RequestRenameWorkspace) !bool {
    if (self.model.request_lifecycle.tracker.has(.workspace_operation)) {
        return false;
    }

    const current = self.model.workspace orelse return false;
    if (!std.meta.eql(current, command.workspace)) {
        return false;
    }

    const request_id = try self.model.request_lifecycle.nextId();
    try self.sendWorkspaceRenameRequest(
        .{
            .request_id = request_id,
            .workspace = command.workspace,
            .name = command.name,
        },
    );

    return true;
}

test "layout export decodes to the same active pane and split tree" {
    try attached_client_tests.layoutRoundTrip(writeCommandLayout);
}

test "host resources reject empty and stale commits before calling ports" {
    try attached_client_tests.rejectStaleHostCommits(deliverHostCommit);
}

test "transport scheduling releases rejected reservations and retries queued frames in order" {
    try attached_client_tests.retryTransportScheduling(startRuntimeSend);
}

test "enqueue retains copied input after rejected scheduling and preserves order on retry" {
    try attached_client_tests.retainQueuedInput(startRuntimeSend);
}

test "change review operation accepts terminal panes and rejects replaced attachments" {
    try attached_client_tests.rejectReplacedReviewAttachment(
        openChangeReviewSession,
        changeReviewOperation,
        applyChangeReviewResponse,
    );
}

test "change review operation updates closed review availability without opening or querying a view" {
    try attached_client_tests.retainReviewAvailability(openChangeReviewSession, changeReviewChanged);
}

test "owned request deliveries roll back only their own correlation when the outbox is full" {
    try attached_client_tests.rollBackFullOutbox(
        sendTabRenameRequest,
        sendCreateTabRequest,
        sendAgentPromptRequest,
    );
}

test "copy mode delegates agent readers after admission and preserves terminal behavior" {
    try copy_mode_tests.agentReaders(enterCopyMode);
}

test "sidebar projection rejects changes that are not the current model commit" {
    try attached_client_tests.rejectStaleSidebarCommits(deliverSidebarLayout);
}
