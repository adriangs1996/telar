//! One attached client's shared state: the model, the runtime transport, the
//! request lifecycle, configuration, plugins and the ports through which a
//! presentation adapter supplies its host. Adapters embed it, build it in
//! place and bind the ports before the first event.
const EditorOpening = @import("links/EditorOpening.zig");

const core = @import("telar-core");
const std = @import("std");
const OptionsType = @import("Options.zig");
const ClientInit = @import("ClientInit.zig");
const AppearanceThemesType = @import("appearance/AppearanceThemes.zig");
const max_expression_paste_bytes_module = @import("config/effects.zig").max_expression_paste_bytes;
const max_encoded_bytes = @import("input/input_namespace.zig").max_encoded_bytes;
const RuntimeTransportState = @import("connection/RuntimeTransportState.zig");
const ClientIdentityType = @import("telar-core").ClientIdentity;
const HostCapabilitiesType = @import("model/HostCapabilities.zig");
const TelemetryState = @import("resources/TelemetryState.zig");
const ClientLayoutsState = @import("resources/ClientLayoutsState.zig");
const StartupState = @import("operations/session/State.zig");
const ModelType = @import("model/Model.zig");
const HistoryType = @import("workspace/History.zig");
const GenerationType = @import("config/Generation.zig");
const RegistryType = @import("plugins/Registry.zig");
const TrustStoreType = @import("telar-core").TrustStore;
const ConfigReloadState = @import("resources/ConfigReloadState.zig");
const SoundPlaybackType = @import("agents/SoundPlayback.zig");
const DeliveryType = @import("notifications/notifications.zig").Delivery;
const CaptureResourcesType = @import("attachments/CaptureResources.zig");
const OpeningType = @import("links/Opening.zig");
const PointerType = @import("links/Pointer.zig");
const LifecycleState = @import("connection/LifecycleState.zig");
const SchedulerType = core.DeadlineScheduler;
const BarUpdatesState = @import("operations/configuration/State.zig");
const key_policy = @import("application/input/key_routing.zig");
const KeyRoutingAuthority = @import("application/input/KeyRoutingAuthority.zig");
const LeasesType = key_policy.Leases;
const RegionType = @import("workspace/Region.zig");
const default_width = @import("layout/sidebar.zig").default_width;
const SoundPortType = @import("agents/SoundPort.zig");
const HostNotifierType = @import("notifications/HostNotifier.zig");
const LinkOpenerType = @import("links/LinkOpener.zig");
const CapturePortType = @import("attachments/CapturePort.zig");
const HostClipboardType = @import("application/panes/Clipboard.zig");
const HostGraphicsType = @import("graphics/HostGraphics.zig");
const GraphicsRetentionType = @import("graphics/GraphicsRetention.zig");
const HostChromeType = @import("presentation/HostChrome.zig");
const AttachmentCatalogPortType = @import("attachments/AttachmentCatalogPort.zig");
const AttachmentShelfType = @import("attachments/AttachmentShelf.zig");
const HostPresentationType = @import("presentation/HostPresentation.zig");
const HostTimersType = @import("resources/HostTimers.zig");
const BarCommandRunnerType = @import("bars/BarCommandRunner.zig");
const PluginWorkerRunnerType = @import("plugins/PluginWorkerRunner.zig");
const PathCompletionRunnerType = @import("completion/PathCompletionRunner.zig");
const PathCompletionsStateType = @import("operations/input/PathCompletionsState.zig");
const FaviconRunnerType = @import("completion/FaviconRunner.zig");
const FaviconsStateType = @import("operations/workspaces/FaviconsState.zig");
const HostClockType = @import("resources/HostClock.zig");
const HostInputSourceType = @import("input/HostInputSource.zig");
const TransportDriverType = @import("connection/TransportDriver.zig");
const ConfigReloadWatcherType = @import("resources/ConfigReloadWatcher.zig");
const ChangeReviewSession = @import("change_review/Session.zig");
const config_reload = @import("resources/config_reload.zig");
const BarConfiguration = @import("bars/Configuration.zig");

comptime {
    std.debug.assert(max_expression_paste_bytes_module + 16 <= max_encoded_bytes);
}

const HostUpdate = @import("model/HostUpdate.zig");
const HostCommit = @import("model/HostCommit.zig");
const HostCapabilityObservation = @import("model/types.zig").HostCapabilityObservation;
const RuntimeOutboundMessage = @import("connection/outbox_support.zig").Message;
const RuntimeMessage = @import("connection/RuntimeMessage.zig");
const pane_graphics = @import("operations/panes/pane_graphics.zig");
const MultiplexerModel = @import("workspace/MultiplexerModel.zig");
const multiplexer = @import("workspace/multiplexer.zig");
const Tab = @import("workspace/Tab.zig");

const parseKey_module = @import("input/chord.zig").parseKey;
const Action = @import("input/action.zig").Action;
const ControlType = @import("input/keybind.zig").Control;
const copy_modes = @import("operations/input/copy_modes.zig");
const name_prompts = @import("operations/input/name_prompts.zig");
const workspace_handoffs = @import("operations/workspaces/workspace_handoffs.zig");
const layout_updates = @import("resources/client_layouts.zig");
const client_detachments = @import("operations/session/client_detachments.zig");
const history_palettes = @import("operations/input/history_palettes.zig");
const suggestions = @import("operations/input/suggestions.zig");
const notification_flow = @import("operations/notifications/notifications.zig");
const tab_selections = @import("operations/tabs/tab_selections.zig");
const PaneFocusTarget = @import("model/types.zig").PaneFocusTarget;
const pane_focus = @import("operations/panes/pane_focus.zig");
const DirectionType = @import("input/action.zig").Direction;
const pane_inputs = @import("operations/input/pane_inputs.zig");
const KeyType = @import("input/Key.zig");
const ScrollDirectionType = @import("input/action.zig").ScrollDirection;
const pane_mouse_input = @import("operations/input/pane_mouse_inputs.zig");
const sidebar_toggles = @import("operations/notifications/sidebar_toggles.zig");
const pane_closures = @import("operations/panes/pane_closures.zig");
const CommandTabType = @import("input/CommandTab.zig");
const tab_creations = @import("operations/tabs/tab_creations.zig");
const tab_closures = @import("operations/tabs/tab_closures.zig");
const tab_moves = @import("operations/tabs/tab_moves.zig");
const key_routing = @import("operations/input/key_routing.zig");
const ApplicationInputLuaActionCommand = @import("application/input/lua_action.zig").Command;
const lua_actions = @import("operations/configuration/lua_actions.zig");
const plugin_actions = @import("operations/configuration/plugin_actions.zig");
const RequestPaneSplit = @import("model/RequestPaneSplit.zig");
const PaneSplit = @import("model/PaneSplit.zig");
const PaneSplitPlan = @import("model/PaneSplitPlan.zig");
const PaneSplitCommit = @import("model/PaneSplitCommit.zig");
const ConfirmPaneSplit = @import("model/ConfirmPaneSplit.zig");
const PaneOpenedType = @import("telar-core").PaneOpened;
const OpenedPaneType = @import("application/panes/OpenedPane.zig");
const WorkspaceCreationType = @import("application/panes/WorkspaceCreation.zig");
const workspace_creations = @import("operations/workspaces/workspace_creations.zig");
const agent_threads = @import("operations/agents/agent_threads.zig");
const PaneAttachmentConfirmationType = @import("application/panes/PaneAttachmentConfirmation.zig");
const agent_reading = @import("application/agents/agent_reading.zig");
const request_failure = @import("application/session/request_failure.zig");
const review_operations = @import("operations/change_review/change_review.zig");
const RequestFailedType = @import("telar-core").RequestFailed;
const ApplicationSessionRequestFailureOutcome = @import("application/session/request_failure.zig").Outcome;
const builtin = @import("builtin");
const link_openings = @import("operations/input/link_openings.zig");
const ServerMessageType = @import("telar-core").ServerMessage;
const agent_sounds = @import("operations/agents/agent_sounds.zig");
const agent_snapshots = @import("operations/agents/agent_snapshots.zig");
const agent_history = @import("operations/agents/agent_history.zig");
const runtime_layouts = @import("operations/session/client_layouts.zig");
const pane_clipboards = @import("operations/panes/pane_clipboards.zig");
const pane_frames = @import("operations/panes/pane_frames.zig");
const client_commands = @import("operations/session/client_commands.zig");
const pane_focus_commands = @import("operations/panes/pane_focus_commands.zig");
const pane_metadata = @import("operations/panes/pane_metadata.zig");
const pane_progress = @import("operations/panes/pane_progress.zig");
const proxy_status = @import("operations/agents/proxy_status.zig");
const resync_requirements = @import("operations/session/resync_requirements.zig");
const system_metrics = @import("operations/agents/system_metrics.zig");
const tab_renames = @import("operations/tabs/tab_renames.zig");
const tab_snapshots = @import("operations/tabs/tab_snapshots.zig");
const workspace_lists = @import("operations/workspaces/workspace_lists.zig");
const workspace_snapshots = @import("operations/workspaces/workspace_snapshots.zig");

/// Bindings obey prompt authority; validated native effects retain their caller's authority.
const ActionOrigin = enum { binding, effect };
const SplitRecovery = enum { restored, not_required, stale };
const PaneOpenOutcome = enum { workspace_arrived, workspace_created, pane_split, pane_attached, ignored };

const ctrl_h = parseKey_module("ctrl+h") catch unreachable;
const ctrl_j = parseKey_module("ctrl+j") catch unreachable;
const ctrl_k = parseKey_module("ctrl+k") catch unreachable;
const ctrl_l = parseKey_module("ctrl+l") catch unreachable;

const ConnectionDelivery = @import("connection/ConnectionDelivery.zig");
const RequestContinuation = @import("connection/requests.zig").Continuation;
const AgentOperation = @import("connection/AgentOperation.zig");
const pane_focus_reports = @import("operations/panes/pane_focus_reports.zig");
const PaneFocus = @import("model/PaneFocus.zig");
const ResizePaneRequest = @import("model/ResizePaneRequest.zig");
const TogglePaneFullscreenRequest = @import("model/TogglePaneFullscreenRequest.zig");
const PaneGeometryChange = @import("model/PaneGeometryChange.zig");
const PaneAttachment = @import("model/PaneAttachment.zig");

const AttachedClient = @This();

io: std.Io,
gpa: std.mem.Allocator,
runtime_transport: RuntimeTransportState,
options: OptionsType,
client_identity: ClientIdentityType,
telemetry: TelemetryState,
client_layouts: ClientLayoutsState = .{},
startup: StartupState = .{},
model: ModelType,
navigation_history: HistoryType = .{},
lua_generation: ?*GenerationType,
plugin_registry: ?*RegistryType,
trust_store: ?*TrustStoreType,
reload: ConfigReloadState,
sound_playback: SoundPlaybackType,
notification_delivery: DeliveryType = .telar,
/// Whether the history palette lists automation-submitted commands too.
history_show_agent_commands: bool = false,
/// Whether Enter in the history palette runs the command instead of only
/// pasting it; shift+enter always does the opposite.
history_enter_runs: bool = false,
/// Whether the palette uses trigram substring matching instead of the
/// default fuzzy subsequence matching.
history_match_fts: bool = false,
/// Transient: the alternate flag of the list submission being finished.
list_submission_alternate: bool = false,
appearance_themes: AppearanceThemesType = .{},
clipboard_capture_resources: CaptureResourcesType = .{},
link_opening: OpeningType = .{},
link_pointer: PointerType = .{},
request_lifecycle: LifecycleState = .{},
change_review: ChangeReviewSession = .{},
sidebar_animation_scheduler: SchedulerType = .{},
notification_scheduler: SchedulerType = .{},
bar_updates: BarUpdatesState = .{},
path_completions: PathCompletionsStateType = .{},
favicons: FaviconsStateType = .{},
/// Application key leases, owned by routing rather than by the host reader.
input_leases: LeasesType = .{},
/// Host ports, bound by the adapter before the first event.
sound_port: SoundPortType = undefined,
notifier: HostNotifierType = undefined,
link_opener: LinkOpenerType = undefined,
editor_open: EditorOpening = .{},
capture_port: CapturePortType = undefined,
host_clipboard: HostClipboardType = undefined,
host_graphics: HostGraphicsType = undefined,
graphics: GraphicsRetentionType = undefined,
chrome: HostChromeType = undefined,
attachment_catalog: AttachmentCatalogPortType = undefined,
attachment_shelf: AttachmentShelfType = undefined,
presentation: HostPresentationType = undefined,
timers: HostTimersType = undefined,
bar_runner: BarCommandRunnerType = undefined,
plugin_runner: PluginWorkerRunnerType = undefined,
path_completion_runner: PathCompletionRunnerType = undefined,
/// Bound only by adapters that draw sprites; unset means no favicon lookups.
favicon_runner: ?FaviconRunnerType = null,
clock: HostClockType = undefined,
host_input_source: HostInputSourceType = undefined,
transport_driver: TransportDriverType = undefined,
config_watcher: ConfigReloadWatcherType = undefined,

/// Builds the shared state in its final address. The model is megabytes, so
/// nothing here passes it by value. Ports remain unbound.
///
/// ```zig
/// try AttachedClient.init(&terminal.app, .{ .gpa = gpa, .io = io, .connection = connection, .host_size = size, .options = options });
/// ```
pub fn init(client: *AttachedClient, params: ClientInit) !void {
    const gpa = params.gpa;
    var capabilities: HostCapabilitiesType = .{
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
    var runtime_transport_state = try RuntimeTransportState.init(gpa, params.connection);
    errdefer runtime_transport_state.deinit(gpa);

    client.* = .{
        .io = params.io,
        .gpa = gpa,
        .runtime_transport = runtime_transport_state,
        .options = params.options,
        .client_identity = params.client_identity,
        .telemetry = .init(params.io, params.options.endpoint),
        .model = undefined,
        .lua_generation = params.options.lua_generation,
        .plugin_registry = params.options.plugin_registry,
        .trust_store = params.options.trust_store,
        .reload = .{ .mtime_ns = params.options.config_mtime_ns },
        .sound_playback = .init(params.options.sound),
    };
    client.model.initInto(gpa, .{
        .pane_gaps = params.options.pane_gaps,
        .configuration_generation = configuration_generation,
        .bars = params.options.bars,
        .host_size = host_size,
        .host_capabilities = capabilities,
        .sidebar_width = default_width,
    });
    errdefer client.model.deinit();
    try client.model.history_palette.prepare(gpa);
    _ = client.model.setSidebarVisible(params.options.sidebar_visible);
}

/// Returns the workbench grid the adapter currently publishes.
/// Example: `const region = client.geometry();`.
pub fn geometry(client: *const AttachedClient) RegionType {
    return client.chrome.region();
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
    client.clipboard_capture_resources.deinit(gpa);
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

/// Owns a routed response until its asynchronous send completes. Example: `try self.sendRuntimeClientCompletion(reply);`
pub fn sendRuntimeClientCompletion(self: *AttachedClient, reply: core.ClientCommand) !void {
    try self.runtime_transport.outbox.pushClientCompletion(reply);
    try self.startRuntimeSend();
}

/// Copies one fixed-size message and starts its write when idle.
/// Example: `try self.sendRuntime(.{ .detach_pane = detach });`
pub fn sendRuntime(self: *AttachedClient, message: RuntimeOutboundMessage) !void {
    try self.runtime_transport.outbox.push(message);
    try self.startRuntimeSend();
}

/// Copies bounded pane input and starts its write when idle.
///
/// ```zig
/// try self.sendRuntimeInput(.{ .pane_id = pane_id, .bytes = bytes });
/// ```
pub fn sendRuntimeInput(self: *AttachedClient, input: core.PaneInput) !void {
    if (input.bytes.len > max_encoded_bytes) {
        try self.runtime_transport.outbox.pushInputBatch(input.pane_id, input.bytes);
    } else {
        try self.runtime_transport.outbox.pushInput(input.pane_id, input.bytes);
    }

    try self.startRuntimeSend();
}

/// Copies a page cursor before its reading window can change.
/// Example: `try self.sendRuntimeAgentHistory(request);`
pub fn sendRuntimeAgentHistory(self: *AttachedClient, request: core.QueryAgentHistory) !void {
    try self.runtime_transport.outbox.pushAgentHistory(request);
    try self.startRuntimeSend();
}

/// Pins a query to copied provider session bytes before the view can change.
/// Example: `try self.sendRuntimeChangeReviewQuery(query);`
pub fn sendRuntimeChangeReviewQuery(self: *AttachedClient, query: core.QueryChangeReview) !void {
    try self.runtime_transport.outbox.pushChangeReviewQuery(query);
    try self.startRuntimeSend();
}

/// Copies comment and path bytes before the originating editor can mutate them.
/// Example: `try self.sendRuntimeChangeReviewCommand(request);`
pub fn sendRuntimeChangeReviewCommand(self: *AttachedClient, request: core.ChangeReviewCommand) !void {
    try self.runtime_transport.outbox.pushChangeReviewCommand(request);
    try self.startRuntimeSend();
}

/// Copies and coalesces one complete reconnectable client layout.
///
/// ```zig
/// try self.sendRuntimeClientLayout(update);
/// ```
pub fn sendRuntimeClientLayout(self: *AttachedClient, update: core.ClientLayoutUpdate) !void {
    try self.runtime_transport.outbox.pushClientLayout(update);
    try self.startRuntimeSend();
}

/// Starts the receive loop before sending the queued bootstrap.
/// Example: `try client.startRuntimeIo();`
pub fn startRuntimeIo(self: *AttachedClient) !void {
    try self.startRuntimeRead();
    try self.startRuntimeSend();
}

/// Reserves a receive buffer and releases it if the driver rejects the read.
/// Example: `try client.startRuntimeRead();`
pub fn startRuntimeRead(self: *AttachedClient) !void {
    const transport = &self.runtime_transport;
    if (!transport.beginRead()) {
        return;
    }

    self.transport_driver.startRead(transport) catch |err| {
        transport.cancelRead();

        return err;
    };
}

/// Keeps queued data owned by the transport if scheduling fails.
fn startRuntimeSend(self: *AttachedClient) !void {
    const transport = &self.runtime_transport;
    const payload = try transport.prepareSend() orelse return;

    self.transport_driver.startSend(transport, payload) catch |err| {
        transport.cancelSend();

        return err;
    };
}

/// Releases one runtime read, dispatches its bounded message and rearms only
/// while the client remains alive.
///
/// ```zig
/// if (try self.receiveRuntime(result)) |status| return status;
/// ```
pub fn receiveRuntime(self: *AttachedClient, result: anyerror!*const RuntimeMessage) !?u8 {
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
pub fn handleServerMessage(self: *AttachedClient, message: ServerMessageType) !?u8 {
    switch (message) {
        .change_review_changed => |notification| {
            _ = review_operations.changed(self, notification);
        },
        .change_review_snapshot => |snapshot| {
            _ = try review_operations.apply(self, snapshot);
        },
        .editor_opened => |reply| {
            try link_openings.editorOpened(self, reply);
        },
        .agent_history_page => |page| {
            _ = try agent_history.apply(self, page);
        },
        .agent_thread_snapshot => |snapshot| {
            _ = try agent_threads.apply(self, snapshot);
        },
        .request_completed => |reply| {
            try agent_threads.completed(self, reply);
        },
        .pane_opened => |opened| _ = try self.completePaneOpen(opened),
        .tab_snapshot => |snapshot| _ = try tab_snapshots.apply(self, snapshot),
        .workspace_snapshot => |snapshot| try workspace_snapshots.apply(self, snapshot),
        .tab_created => |created| _ = try tab_creations.apply(self, created),
        .tab_renamed => |renamed| _ = try tab_renames.apply(self, renamed),
        .tab_closed => |closed| switch (try tab_closures.apply(self, closed)) {
            .applied, .ignored => {},
            .exit => return 0,
        },
        .tab_moved => |moved| _ = try tab_moves.apply(self, moved),
        .pane_frame => |frame| _ = try pane_frames.apply(self, frame),
        .pane_cwd => |cwd| _ = try pane_metadata.applyCwd(self, cwd),
        .pane_foreground => |foreground| _ = try pane_metadata.applyForeground(self, foreground),
        .pane_title => |title| _ = try pane_metadata.applyTitle(self, title),
        .pane_progress => |progress| _ = try pane_progress.apply(self, progress),
        .client_command => |command| try client_commands.apply(self, command),
        .pane_focus_command => |command| try pane_focus_commands.apply(self, command),
        .pane_matches => |found| _ = try copy_modes.matches(self, found),
        .pane_clipboard => |clipboard| try pane_clipboards.apply(self, clipboard),
        .pane_exited => |exited| _ = try pane_closures.applyExit(self, exited),
        .request_failed => |failure| {
            if (!history_palettes.failed(self, failure)) {
                _ = try self.failRuntimeRequest(failure);
            }
        },
        .notification => |notification| _ = try notification_flow.applyRuntime(self, notification),
        .notification_shown => |shown| _ = try notification_flow.applyDeliveryReport(self, shown),
        .agent_sound => |sound| _ = try agent_sounds.apply(self, sound),
        .client_layout_snapshot => |snapshot| try runtime_layouts.apply(self, snapshot),
        .resync_required => |required| {
            if (try resync_requirements.apply(self, required) == .exit) {
                return 0;
            }
        },
        .runtime_stopping => return 0,
        .history_results => |results| _ = try history_palettes.apply(self, results),
        .history_pruned => |confirmation| _ = try history_palettes.pruned(self, confirmation),
        .history_output => |output| _ = history_palettes.output(self, output),
        .command_suggestion => |suggested| _ = try suggestions.apply(self, suggested),
        .client_command_result, .client_list, .pane_text, .history_stats_result, .pane_focus_result => return error.UnexpectedControlReply,
        .proxy_status => |status| _ = try proxy_status.apply(self, status),
        .agent_snapshot => |snapshot| _ = try agent_snapshots.apply(self, snapshot),
        .system_metrics => |metrics| _ = try system_metrics.apply(self, metrics),
        .workspace_list => |list| _ = try workspace_lists.apply(self, list),
        .graphics_snapshot => |snapshot| _ = try pane_graphics.apply(
            self,
            .{
                .snapshot = snapshot,
            },
        ),
        .graphics_image => |image| _ = try pane_graphics.apply(
            self,
            .{
                .image = image,
            },
        ),
        .graphics_shared_image => |image| _ = try pane_graphics.apply(
            self,
            .{
                .shared_image = image,
            },
        ),
        .graphics_image_chunk => |chunk| _ = try pane_graphics.apply(
            self,
            .{
                .image_chunk = chunk,
            },
        ),
        .graphics_placement => |placement| _ = try pane_graphics.apply(
            self,
            .{
                .placement = placement,
            },
        ),
        .graphics_delete_image => |deleted| _ = try pane_graphics.apply(
            self,
            .{
                .delete_image = deleted,
            },
        ),
        .graphics_delete_placement => |deleted| _ = try pane_graphics.apply(
            self,
            .{
                .delete_placement = deleted,
            },
        ),
    }
    return null;
}

/// Executes a binding or a validated native effect with its existing prompt policy.
/// Example: `_ = try self.executeAction(.{ .split_pane = .horizontal }, .binding);`
pub fn executeAction(self: *AttachedClient, value: Action, origin: ActionOrigin) anyerror!ControlType {
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
            _ = try plugin_actions.start(
                self,
                requested,
                self.model.callbackContext(),
            );
            return .continue_routing;
        },
        else => {},
    }

    if (value != .enter_copy_mode and copy_modes.active(self)) {
        _ = try copy_modes.leave(self);
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
        .focus_pane => |direction| _ = try self.focusPane(
            .{
                .direction = switch (direction) {
                    .left => .left,
                    .right => .right,
                    .up => .up,
                    .down => .down,
                },
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
        .toggle_sidebar => _ = try sidebar_toggles.toggle(self),
        .resize_sidebar => |direction| _ = try sidebar_toggles.resize(
            self,
            .{
                .direction = switch (direction) {
                    .left => .narrower,
                    .right => .wider,
                },
            },
        ),
        .toggle_workspace_list => _ = self.model.toggleWorkspaceList(),
        .new_workspace => _ = name_prompts.beginWorkspaceCreate(self),
        .rename_workspace => _ = name_prompts.beginWorkspaceRename(self),
        .select_workspace => |position| _ = try workspace_handoffs.selectWorkspace(
            self,
            .{
                .position = position,
            },
        ),
        .close_pane => _ = try pane_closures.request(self),
        .new_tab => _ = try tab_creations.request(
            self,
            .{},
        ),
        .new_agent_tab => try agent_threads.create(self),
        .select_tab_offset => |offset| _ = try tab_selections.select(
            self,
            .{
                .target = .{
                    .offset = offset,
                },
            },
        ),
        .select_tab => |position| _ = try tab_selections.select(
            self,
            .{
                .target = .{
                    .position = position,
                },
            },
        ),
        .rename_tab => _ = name_prompts.beginActiveTabRename(self),
        .close_tab => _ = try tab_closures.request(self),
        .move_tab => |direction| _ = try tab_moves.request(
            self,
            .{
                .direction = switch (direction) {
                    .previous => .previous,
                    .next => .next,
                },
            },
        ),
        .detach => {
            try layout_updates.observe(self);
            try client_detachments.apply(self);

            return .stop;
        },
        .enter_copy_mode => _ = copy_modes.enter(self),
        .command_tab => |*command| try self.createCommandTab(command),
        .goto_picker => _ = name_prompts.beginGotoPicker(self),
        .history_palette => _ = try history_palettes.begin(self),
        .suggest_command => _ = try suggestions.begin(self),
        .notification => |*notification| _ = try notification_flow.requestDelivery(self, notification),
        .lua_callback, .lua_expr, .plugin => unreachable,
    }

    return .continue_routing;
}

fn focusPane(self: *AttachedClient, target: PaneFocusTarget) !bool {
    return try pane_focus.apply(
        self,
        .{
            .target = target,
            .area = self.geometry().area,
        },
    ) != null;
}

fn navigatePane(self: *AttachedClient, direction: DirectionType) !void {
    const key = navigationKey(direction);
    if (std.mem.eql(
        u8,
        self.model.focusedPaneForeground(),
        "nvim",
    )) {
        _ = try pane_inputs.send(
            self,
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

    _ = try self.focusPane(
        .{
            .direction = switch (direction) {
                .left => .left,
                .right => .right,
                .up => .up,
                .down => .down,
            },
        },
    );
}

fn navigationKey(direction: DirectionType) KeyType {
    return switch (direction) {
        .left => ctrl_h,
        .right => ctrl_l,
        .up => ctrl_k,
        .down => ctrl_j,
    };
}

fn scrollPane(self: *AttachedClient, direction: ScrollDirectionType) !void {
    const model = self.model.activeTabModel() orelse return;

    _ = try pane_mouse_input.apply(
        self,
        model,
        .{
            .focused_scroll = direction,
        },
    );
}

fn createCommandTab(self: *AttachedClient, command: *const CommandTabType) !void {
    var arguments: [CommandTabType.max_arguments][]const u8 = undefined;
    for (0..command.argument_count) |index| {
        arguments[index] = command.argument(index);
    }

    _ = try tab_creations.request(
        self,
        .{
            .label = command.label(),
            .arguments = arguments[0..command.argument_count],
        },
    );
}

fn executeLuaAction(self: *AttachedClient, command: ApplicationInputLuaActionCommand) !ControlType {
    const copy_mode_active = copy_modes.active(self);
    const outcome = try lua_actions.execute(self, command);
    switch (outcome) {
        .applied, .unavailable, .invocation_failed, .validation_failed => return .continue_routing,
        .exit => return .stop,
        .input => |decision| switch (decision) {
            .consume => {},
            .forward_binding, .keys => |keys| for (keys.slice()) |key| {
                _ = try key_routing.apply(
                    self,
                    .{
                        .key = key,
                    },
                );
            },
            .paste => |paste| {
                if (!copy_mode_active) {
                    _ = try pane_inputs.expressionPaste(self, paste.slice());
                }
            },
        },
    }

    return .continue_routing;
}

/// Registers correlation before copying the request; failed delivery removes only that registration.
/// Example: `try self.sendRuntimeRequest(delivery);`
pub fn sendRuntimeRequest(self: *AttachedClient, delivery: ConnectionDelivery) !void {
    try self.request_lifecycle.tracker.add(delivery.registration.request_id, delivery.registration.continuation);
    errdefer _ = self.request_lifecycle.tracker.take(delivery.registration.request_id);
    try self.runtime_transport.outbox.push(delivery.message);
    try self.startRuntimeSend();
}

/// Registers correlation before copying the request; failed delivery removes only that registration.
/// Example: `try self.sendTabRenameRequest(rename, continuation);`
pub fn sendTabRenameRequest(self: *AttachedClient, rename: core.RenameTab, continuation: RequestContinuation) !void {
    try self.request_lifecycle.tracker.add(rename.request_id, continuation);
    errdefer _ = self.request_lifecycle.tracker.take(rename.request_id);
    try self.runtime_transport.outbox.pushRename(rename);
    try self.startRuntimeSend();
}

/// Registers correlation before copying the request; failed delivery removes only that registration.
/// Example: `try self.sendWorkspaceRenameRequest(rename);`
pub fn sendWorkspaceRenameRequest(self: *AttachedClient, rename: core.RenameWorkspace) !void {
    try self.request_lifecycle.tracker.add(
        rename.request_id,
        .{
            .rename_workspace = rename.workspace,
        },
    );
    errdefer _ = self.request_lifecycle.tracker.take(rename.request_id);
    try self.runtime_transport.outbox.pushWorkspaceRename(rename);
    try self.startRuntimeSend();
}

/// Registers correlation before copying the request; failed delivery removes only that registration.
/// Example: `try self.sendCreateWorkspaceRequest(request);`
pub fn sendCreateWorkspaceRequest(self: *AttachedClient, request: core.CreateWorkspace) !void {
    try self.request_lifecycle.tracker.add(
        request.request_id,
        .{
            .create_workspace = request.size,
        },
    );
    errdefer _ = self.request_lifecycle.tracker.take(request.request_id);
    try self.runtime_transport.outbox.pushCreateWorkspace(request);
    try self.startRuntimeSend();
}

/// Registers correlation before copying the request; failed delivery removes only that registration.
/// Example: `try self.sendCreateTabRequest(request);`
pub fn sendCreateTabRequest(self: *AttachedClient, request: core.CreateTab) !void {
    try self.request_lifecycle.tracker.add(
        request.request_id,
        .{
            .create_tab = .{
                .workspace = request.workspace,
                .size = request.size,
            },
        },
    );
    errdefer _ = self.request_lifecycle.tracker.take(request.request_id);
    try self.runtime_transport.outbox.pushCreateTab(request);
    try self.startRuntimeSend();
}

/// Registers correlation before copying the request; failed delivery removes only that registration.
/// Example: `try self.sendAgentPromptRequest(request, operation);`
pub fn sendAgentPromptRequest(self: *AttachedClient, request: core.AgentPrompt, operation: AgentOperation) !void {
    try self.request_lifecycle.tracker.add(
        request.request_id,
        .{
            .agent_prompt = operation,
        },
    );
    errdefer _ = self.request_lifecycle.tracker.take(request.request_id);
    try self.runtime_transport.outbox.pushAgentPrompt(request);
    try self.startRuntimeSend();
}

/// Registers correlation before copying the request; failed delivery removes only that registration.
/// Example: `try self.sendNotificationRequest(request);`
pub fn sendNotificationRequest(self: *AttachedClient, request: core.ShowNotification) !void {
    try self.request_lifecycle.tracker.add(request.request_id, .notification);
    errdefer _ = self.request_lifecycle.tracker.take(request.request_id);
    try self.runtime_transport.outbox.pushNotification(request);
    try self.startRuntimeSend();
}

/// Requests a canonical snapshot with its exact target retained until the reply.
/// Example: `try self.requestTabSnapshot(location);`
pub fn requestTabSnapshot(self: *AttachedClient, location: core.TabLocation) !void {
    const request_id = try self.request_lifecycle.nextId();
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
pub fn requestWorkspaceSnapshot(self: *AttachedClient, workspace: core.WorkspaceLocation) !void {
    const request_id = try self.request_lifecycle.nextId();
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

/// Synchronizes the focused attachment before reporting child focus. Example: `try self.synchronizeActivePane();`
pub fn synchronizeActivePane(self: *AttachedClient) !void {
    _ = try self.synchronizePaneAttachments();
    _ = try pane_focus_reports.sync(self);
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

    if (self.model.workspace.active()) |tab| {
        try self.resizeAttachedPanes(&tab.model, self.geometry().area);
    }

    return true;
}

/// Delivers resources for a committed focus, including newly revealed panes. Example: `try self.deliverPaneFocus(focus, area);`
pub fn deliverPaneFocus(self: *AttachedClient, focus: PaneFocus, area: core.Rect) !void {
    const active = self.model.workspace.active() orelse return error.StalePaneFocus;
    if (!std.meta.eql(active.location, focus.location) or
        active.model.layout.focused() != focus.focused or
        self.model.version().panes != focus.panes_revision)
    {
        return error.StalePaneFocus;
    }

    try self.synchronizeActivePane();
    if (!focus.geometry_changed) {
        return;
    }

    self.host_graphics.invalidatePlacements();
    try self.resizeAttachedPanes(&active.model, area);

    if (active.snapshot_loaded) {
        try self.attachVisiblePanes(active, area);
    }
}

/// Commits one split-edge move before delivering geometry. Example: `_ = try self.resizePane(command);`
pub fn resizePane(self: *AttachedClient, command: ResizePaneRequest) !?PaneGeometryChange {
    const change = self.model.resizePane(command) orelse return null;
    try self.deliverPaneGeometry(change);

    return change;
}

/// Commits fullscreen state before delivering geometry. Example: `_ = try self.togglePaneFullscreen(command);`
pub fn togglePaneFullscreen(self: *AttachedClient, command: TogglePaneFullscreenRequest) !?PaneGeometryChange {
    const change = self.model.togglePaneFullscreen(command) orelse return null;
    try self.deliverPaneGeometry(change);

    return change;
}

/// Rejects obsolete geometry before invalidating placements and resizing attachments.
fn deliverPaneGeometry(self: *AttachedClient, change: PaneGeometryChange) !void {
    const active = self.model.workspace.active() orelse return error.StalePaneGeometry;
    if (!std.meta.eql(active.location, change.location) or
        active.model.layout.focused() != change.focused or
        active.model.layout.isFullscreen() != change.fullscreen or
        self.model.version().panes != change.panes_revision)
    {
        return error.StalePaneGeometry;
    }

    self.host_graphics.invalidatePlacements();
    try self.resizeAttachedPanes(&active.model, change.area);

    if (active.snapshot_loaded) {
        try self.attachVisiblePanes(active, change.area);
    }
}

/// A failed attachment repairs membership only while that pane is still detached.
fn recoverPaneAttachment(self: *AttachedClient, attachment: PaneAttachment) !bool {
    if (!self.model.needsPaneAttachment(attachment)) {
        return false;
    }

    _ = try tab_snapshots.recover(self, attachment.location);
    return true;
}

/// Requests creation without committing layout; restores geometry if delivery fails.
/// Example: `_ = try self.requestPaneSplit(.{ .axis = .horizontal, .area = self.geometry().area });`
pub fn requestPaneSplit(self: *AttachedClient, command: RequestPaneSplit) !?PaneSplitPlan {
    if (self.request_lifecycle.tracker.has(.pane_operation)) {
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

fn sendPaneSplitRequest(self: *AttachedClient, plan: PaneSplitPlan) !void {
    const request_id = try self.request_lifecycle.nextId();
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
fn confirmPaneSplit(self: *AttachedClient, command: ConfirmPaneSplit) !PaneSplitCommit {
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
            const tab = self.model.workspace.find(commit.location.tab_id).?;
            try self.resizeAttachedPanes(&tab.model, commit.area);
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
            if (self.model.workspace.findPane(commit.pane_id) != null) {
                return error.StalePaneSplitConfirmation;
            }

            try self.sendRuntime(
                .{
                    .detach_pane = .{
                        .pane_id = commit.pane_id,
                    },
                },
            );
            if (self.model.workspace.workspace) |workspace| {
                if (std.meta.eql(workspace, commit.location.workspace) and !self.request_lifecycle.tracker.has(.workspace_snapshot)) {
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
fn recoverPaneSplit(self: *AttachedClient, split: PaneSplit) !SplitRecovery {
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
fn completePaneOpen(self: *AttachedClient, opened: PaneOpenedType) !PaneOpenOutcome {
    const continuation = self.request_lifecycle.tracker.take(opened.request_id) orelse
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
        try agent_threads.opened(self, opened);
    }

    return outcome;
}

fn translateOpenedPane(opened: PaneOpenedType) OpenedPaneType {
    return .{
        .pane_id = opened.pane_id,
        .location = opened.location,
        .created = opened.created,
    };
}

fn arriveOpenedWorkspace(self: *AttachedClient, opened: OpenedPaneType) !void {
    try workspace_handoffs.confirm(self, try workspace_handoffs.arrival(self, opened));
}

fn createOpenedWorkspace(self: *AttachedClient, confirmation: WorkspaceCreationType) !void {
    _ = try workspace_creations.confirm(self, workspace_creations.confirmation(
        self,
        confirmation.opened,
        confirmation.requested_size,
    ));
}

/// Rejects mismatched or newly created panes before committing an attachment.
fn confirmPaneAttachment(self: *AttachedClient, confirmation: PaneAttachmentConfirmationType) !void {
    const confirmed: PaneAttachment = .{
        .pane_id = confirmation.opened.pane_id,
        .location = confirmation.opened.location,
    };
    if (confirmation.opened.created or !std.meta.eql(confirmation.requested, confirmed)) {
        return error.UnexpectedPane;
    }

    _ = try self.model.confirmPaneAttachment(confirmed);
}

/// Recovers the correlated operation before publishing its failure notification.
fn failRuntimeRequest(self: *AttachedClient, failure: RequestFailedType) !ApplicationSessionRequestFailureOutcome {
    const continuation = self.request_lifecycle.tracker.take(failure.request_id) orelse {
        reportRuntimeFailure(failure.message);

        return error.UnexpectedRequestFailure;
    };
    if (continuation == .ignored) {
        review_operations.retired(self, failure.request_id);
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
            if (!review_operations.failed(
                self,
                operation,
                failure.message,
            )) {
                return .ignored;
            }
        },
        else => {},
    }
    _ = self.editor_open.complete(failure.request_id);

    errdefer reportRuntimeFailure(failure.message);
    switch (continuation) {
        .ignored => return .ignored,
        .workspace_snapshot, .tab_snapshot => return error.RuntimeRequestFailed,
        .initial_open => |open| {
            const outcome = try workspace_handoffs.recover(
                self,
                .{
                    .fallback_workspace = open.fallback_workspace,
                    .code = failure.code,
                },
            );
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
            _ = try tab_closures.recover(self, location);
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

    try notification_flow.publishNow(self, request_failure.notification(
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
    try self.host_input_source.resumeRead();
}

/// Returns available graphics credits and starts their delivery.
/// Example: `try client.flushGraphicsCredits();`
pub fn flushGraphicsCredits(self: *AttachedClient) !void {
    self.queueGraphicsCredits();
    try self.startRuntimeSend();
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

/// Commits validated geometry before touching resources. Delivery failure keeps
/// the committed state; the caller ends the client session.
/// Example: `_ = try self.applyHostUpdate(update);`
pub fn applyHostUpdate(self: *AttachedClient, update: HostUpdate) !?HostCommit {
    const commit = try self.model.reconcileHost(update) orelse return null;

    try self.deliverHostCommit(commit);

    return commit;
}

/// Applies a semantic terminal response through the same resource policy.
/// Example: `_ = try self.observeHostCapability(observation);`
pub fn observeHostCapability(self: *AttachedClient, observation: HostCapabilityObservation) !?HostCommit {
    const commit = try self.model.observeHostCapability(observation) orelse return null;

    try self.deliverHostCommit(commit);

    return commit;
}

/// Resolves geometry when a probe settles a complete set of capabilities.
/// Example: `_ = try self.reconcileHostCapabilities(capabilities);`
pub fn reconcileHostCapabilities(self: *AttachedClient, capabilities: HostCapabilitiesType) !?HostCommit {
    var size = self.model.hostSize();
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

/// Delivers a current commit, stopping at the first failed resource operation.
fn deliverHostCommit(self: *AttachedClient, commit: HostCommit) !void {
    try validateHostCommit(&self.model, commit);

    if (commit.capabilities) |change| {
        if (!std.meta.eql(change.previous.terminal_colors, change.current.terminal_colors) and
            (self.startup.phase == .opening or self.startup.phase == .active))
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
                .light => self.appearance_themes.light,
                .dark => self.appearance_themes.dark,
            };

            if (theme) |value| {
                self.chrome.setTheme(value);
            }
        }

        if (change.previous.images != change.current.images) {
            pane_graphics.syncFallbacks(&self.model, self.graphics);

            const size = self.model.hostSize();
            try self.chrome.configureSidebar(
                .{
                    .support = change.current.images,
                    .cell_width = size.cell_width_px,
                    .cell_height = size.cell_height_px,
                },
            );
            self.host_graphics.invalidatePlacements();
        }
    }

    if (commit.resize) |resize| {
        if (resize.grid_changed) {
            try self.presentation.resize(resize.current.cols, resize.current.rows);
            try self.chrome.resize(resize.current.cols, resize.current.rows);
        }

        if (resize.cell_size_changed) {
            try self.chrome.configureSidebar(
                .{
                    .support = self.model.hostCapabilities().images,
                    .cell_width = resize.current.cell_width_px,
                    .cell_height = resize.current.cell_height_px,
                },
            );
        }

        self.host_graphics.invalidatePlacements();
        if (self.model.workspace.active()) |tab| {
            const area = self.geometry().area;
            try self.resizeAttachedPanes(&tab.model, area);

            if (tab.snapshot_loaded) {
                try self.attachVisiblePanes(tab, area);
            }
        }
    }
}

/// Offers sizes for attached visible panes, reserving space for the attachment shelf.
/// Example: `try self.resizeAttachedPanes(&tab.model, area);`
pub fn resizeAttachedPanes(self: *AttachedClient, model: *MultiplexerModel, area: core.Rect) !void {
    var layout = model.layoutSnapshot(area).*;
    _ = layout.reserveBelowPane(self.attachment_shelf.reservation());
    var panes = model.paneIterator();

    while (panes.next()) |pane| {
        if (!pane.attached) {
            continue;
        }

        const view = layout.find(pane.id) orelse continue;
        var size = multiplexer.rectSize(view.content) orelse continue;
        size.cell_width_px = model.cell_width_px;
        size.cell_height_px = model.cell_height_px;
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

/// Connects visible detached panes after canonical membership is loaded.
/// Pending attachments are coalesced; failed delivery rolls back its correlation.
/// Example: `if (tab.snapshot_loaded) { try self.attachVisiblePanes(tab, area); }`
pub fn attachVisiblePanes(self: *AttachedClient, tab: *Tab, area: core.Rect) !void {
    std.debug.assert(tab.snapshot_loaded);
    var panes = tab.model.paneIterator();

    while (panes.next()) |pane| {
        if (pane.attached or self.request_lifecycle.tracker.hasPane(.attachment, pane.id)) {
            continue;
        }

        const size = tab.model.contentSize(pane.id, area) orelse continue;
        const request_id = try self.request_lifecycle.nextId();
        try self.sendRuntimeRequest(
            .{
                .registration = .{
                    .request_id = request_id,
                    .continuation = .{
                        .attach_pane = .{
                            .pane_id = pane.id,
                            .location = tab.location,
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

fn validateHostCommit(model: *const ModelType, commit: HostCommit) !void {
    if (commit.capabilities == null and commit.resize == null) {
        return error.EmptyHostCommit;
    }

    const version = model.version();

    if (commit.capabilities) |change| {
        if (!std.meta.eql(model.hostCapabilities(), change.current) or
            version.host_capabilities != change.host_capabilities_revision)
        {
            return error.StaleHostCommit;
        }
    }

    if (commit.resize) |resize| {
        if (!std.meta.eql(model.hostSize(), resize.current) or version.host != resize.host_revision) {
            return error.StaleHostCommit;
        }
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
            .watcher = self.config_watcher,
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
pub fn barConfiguration(self: *const AttachedClient) ?*const BarConfiguration {
    const generation = self.lua_generation orelse return null;

    if (generation.number != self.model.configurationGeneration()) {
        return null;
    }

    return &generation.snapshot.bars;
}

/// Replaces bar deadlines from the active configuration and rearms their timer.
/// Example: `try client.synchronizeBars();`
pub fn synchronizeBars(self: *AttachedClient) !void {
    self.bar_updates.synchronize(
        .{
            .generation = if (self.lua_generation) |generation| generation.number else self.model.configurationGeneration(),
            .configuration = self.barConfiguration(),
            .now_ns = core.monotonic(self.io),
        },
    );

    try self.bar_updates.rearm(self.io, self.timers);
}

/// Snapshot the current exclusive keyboard owners without exposing client state.
/// Example: `const captures_keys = key_policy.captures(self.keyRoutingAuthority());`
pub fn keyRoutingAuthority(self: *const AttachedClient) KeyRoutingAuthority {
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
    if (key_policy.captures(authority) or authority.copy_mode_active) {
        return null;
    }

    const model = self.model.activeTabModelConst() orelse return null;
    const pane = model.focusedPaneConst() orelse return null;
    return if (pane.attached) pane.id else null;
}

test "host resources reject empty and stale commits before calling ports" {
    const app = try std.testing.allocator.create(AttachedClient);
    defer std.testing.allocator.destroy(app);
    // Only the model is initialized: invalid commits must never reach a host port.
    app.model.initInto(
        std.testing.allocator,
        .{
            .pane_gaps = false,
            .host_size = .{
                .cols = 80,
                .rows = 24,
            },
        },
    );
    defer app.model.deinit();

    const stale_capabilities = (try app.model.observeHostCapability(
        .{
            .images = .supported,
        },
    )).?;
    _ = try app.model.observeHostCapability(
        .{
            .pointer_pixels = .supported,
        },
    );
    const stale_size = (try app.model.reconcileHost(
        .{
            .capabilities = app.model.hostCapabilities(),
            .size = .{
                .cols = 100,
                .rows = 30,
            },
        },
    )).?;
    _ = try app.model.reconcileHost(
        .{
            .capabilities = app.model.hostCapabilities(),
            .size = .{
                .cols = 101,
                .rows = 30,
            },
        },
    );

    try std.testing.expectError(error.EmptyHostCommit, app.deliverHostCommit(
        .{
            .capabilities = null,
            .resize = null,
        },
    ));
    try std.testing.expectError(error.StaleHostCommit, app.deliverHostCommit(stale_capabilities));
    try std.testing.expectError(error.StaleHostCommit, app.deliverHostCommit(stale_size));
}

test "transport scheduling releases rejected reservations and retries queued frames in order" {
    const Driver = struct {
        reject: bool = true,
        reads: usize = 0,
        sends: usize = 0,
        payload: []const u8 = &.{},

        fn read(raw: *anyopaque, state: *RuntimeTransportState) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.reads += 1;
            try std.testing.expect(state.receive_pending);

            if (self.reject) {
                return error.DriverBusy;
            }
        }

        fn send(raw: *anyopaque, state: *RuntimeTransportState, payload: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.sends += 1;
            self.payload = payload;
            try std.testing.expect(state.outbox.inFlight());

            if (self.reject) {
                return error.DriverBusy;
            }
        }
    };

    var capture: Driver = .{};
    const driver: TransportDriverType = .{
        .context = &capture,
        .start_read_fn = Driver.read,
        .start_send_fn = Driver.send,
    };
    var send_buffer: [64]u8 = undefined;
    const app = try std.testing.allocator.create(AttachedClient);
    defer std.testing.allocator.destroy(app);
    app.transport_driver = driver;
    const state = &app.runtime_transport;
    state.* = .{
        .connection = undefined,
        .send_buffer = &send_buffer,
        .receive_buffer = &.{},
        .read_buffer = &.{},
    };

    try std.testing.expectError(error.DriverBusy, app.startRuntimeRead());
    try std.testing.expect(!state.receive_pending);
    capture.reject = false;
    try app.startRuntimeRead();
    try app.startRuntimeRead();
    try std.testing.expectEqual(@as(usize, 2), capture.reads);
    try std.testing.expectError(error.ReadFailed, state.completeRead(error.ReadFailed));
    try std.testing.expect(!state.receive_pending);
    try app.startRuntimeRead();
    try std.testing.expectEqual(@as(usize, 3), capture.reads);
    state.cancelRead();

    try app.startRuntimeSend();
    try std.testing.expectEqual(@as(usize, 0), capture.sends);
    try state.outbox.push(
        .{
            .detach_pane = .{
                .pane_id = @enumFromInt(1),
            },
        },
    );
    try state.outbox.push(
        .{
            .detach_pane = .{
                .pane_id = @enumFromInt(2),
            },
        },
    );
    capture.reject = true;
    try std.testing.expectError(error.DriverBusy, app.startRuntimeSend());
    try std.testing.expect(!state.outbox.inFlight());
    try std.testing.expectEqual(@as(u8, 2), state.outbox.len);
    const first = send_buffer;
    const first_len = capture.payload.len;
    capture.reject = false;
    try app.startRuntimeSend();
    try std.testing.expectEqualSlices(
        u8,
        first[0..first_len],
        capture.payload,
    );
    try app.startRuntimeSend();
    try std.testing.expectEqual(@as(usize, 2), capture.sends);
    try state.outbox.finishSend({});
    try app.startRuntimeSend();
    try std.testing.expectEqual(@as(usize, 3), capture.sends);
    try std.testing.expect(!std.mem.eql(
        u8,
        first[0..first_len],
        capture.payload,
    ));
    try state.outbox.finishSend({});
    try std.testing.expectEqual(@as(u8, 0), state.outbox.len);
}

test "enqueue retains copied input after rejected scheduling and preserves order on retry" {
    const Driver = struct {
        reject: bool = true,
        sends: usize = 0,
        payload: []const u8 = &.{},

        fn read(_: *anyopaque, _: *RuntimeTransportState) !void {
            return error.UnexpectedRead;
        }

        fn send(raw: *anyopaque, _: *RuntimeTransportState, payload: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.sends += 1;

            if (self.reject) {
                return error.DriverBusy;
            }

            self.payload = payload;
        }
    };

    var capture: Driver = .{};
    const driver: TransportDriverType = .{
        .context = &capture,
        .start_read_fn = Driver.read,
        .start_send_fn = Driver.send,
    };
    var send_buffer: [max_encoded_bytes + 64]u8 = undefined;
    const app = try std.testing.allocator.create(AttachedClient);
    defer std.testing.allocator.destroy(app);
    app.transport_driver = driver;
    const state = &app.runtime_transport;
    state.* = .{
        .connection = undefined,
        .send_buffer = &send_buffer,
        .receive_buffer = &.{},
        .read_buffer = &.{},
    };
    const pane: core.PaneId = @enumFromInt(1);
    var source = [_]u8{
        'x',
    } ** (max_encoded_bytes + 1);

    try std.testing.expectError(error.DriverBusy, app.sendRuntimeInput(
        .{
            .pane_id = pane,
            .bytes = &source,
        },
    ));
    try std.testing.expectEqual(@as(u8, 2), state.outbox.len);
    try std.testing.expect(!state.outbox.inFlight());
    @memset(&source, 'y');
    capture.reject = false;

    try app.sendRuntime(
        .{
            .detach_pane = .{
                .pane_id = pane,
            },
        },
    );
    const first = try core.decodeClient(capture.payload);
    try std.testing.expect(first == .pane_input);
    try std.testing.expectEqual(pane, first.pane_input.pane_id);
    try std.testing.expectEqualStrings("x" ** max_encoded_bytes, first.pane_input.bytes);
    try state.outbox.finishSend({});
    try app.startRuntimeSend();
    const second = try core.decodeClient(capture.payload);
    try std.testing.expect(second == .pane_input);
    try std.testing.expectEqualStrings("x", second.pane_input.bytes);
    try state.outbox.finishSend({});
    try app.startRuntimeSend();
    const third = try core.decodeClient(capture.payload);
    try std.testing.expect(third == .detach_pane);
    try std.testing.expectEqual(pane, third.detach_pane.pane_id);
    try state.outbox.finishSend({});
    try std.testing.expectEqual(@as(u8, 0), state.outbox.len);

    while (state.outbox.hasCapacity()) {
        try state.outbox.push(
            .{
                .detach_pane = .{
                    .pane_id = pane,
                },
            },
        );
    }

    const sends = capture.sends;
    try std.testing.expectError(error.ClientOutboxFull, app.sendRuntime(
        .{
            .detach_pane = .{
                .pane_id = pane,
            },
        },
    ));
    try std.testing.expectEqual(sends, capture.sends);
    try std.testing.expect(!state.outbox.inFlight());
}
