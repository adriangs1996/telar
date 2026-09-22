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
const PaneAttachmentConfirmationType = @import("application/panes/PaneAttachmentConfirmation.zig");
const agent_reading = @import("application/agents/agent_reading.zig");
const request_failure = @import("application/session/request_failure.zig");
const RequestFailedType = @import("telar-core").RequestFailed;
const ApplicationSessionRequestFailureOutcome = @import("application/session/request_failure.zig").Outcome;
const builtin = @import("builtin");
const ServerMessageType = @import("telar-core").ServerMessage;
const agent_sounds = @import("operations/agents/agent_sounds.zig");
const agent_snapshots = @import("operations/agents/agent_snapshots.zig");
const runtime_layouts = @import("operations/session/client_layouts.zig");
const pane_clipboards = @import("operations/panes/pane_clipboards.zig");
const pane_frames = @import("operations/panes/pane_frames.zig");
const pane_focus_commands = @import("operations/panes/pane_focus_commands.zig");
const pane_metadata = @import("operations/panes/pane_metadata.zig");
const pane_progress = @import("operations/panes/pane_progress.zig");
const proxy_status = @import("operations/agents/proxy_status.zig");
const resync_requirements = @import("operations/session/resync_requirements.zig");
const system_metrics = @import("operations/agents/system_metrics.zig");
const workspace_lists = @import("operations/workspaces/workspace_lists.zig");

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

const config_reloads = @import("operations/configuration/config_reloads.zig");
const config_queries = @import("operations/configuration/config_queries.zig");
const plugin_queries = @import("operations/configuration/plugin_queries.zig");
const plugin_toggles = @import("operations/configuration/plugin_toggles.zig");
const plugin_invocations = @import("operations/configuration/plugin_invocations.zig");
const SplitAxis = @import("workspace/layout_support.zig").Axis;
const LayoutDirection = @import("workspace/layout_support.zig").Direction;
const pane_viewports = @import("operations/panes/pane_viewports.zig");
const LinkTarget = @import("links/LinkTarget.zig");
const WorkspaceLayout = @import("workspace/WorkspaceLayout.zig");

const Pane = @import("panes/Pane.zig");
const ChangeReviewOperation = @import("connection/ChangeReviewOperation.zig");
const MouseType = @import("input/Mouse.zig");
const LinkPointerCommand = @import("links/PointerCommand.zig");
const RectType = @import("telar-core").Rect;
const extract_module = @import("links/cells.zig").extract;
const FilePathType = @import("links/FilePath.zig");
const PaneId = @import("telar-core").PaneId;
const AgentHistoryOperation = @import("connection/AgentHistoryOperation.zig");
const AgentDecision = @import("application/agents/AgentDecision.zig");
const TabSnapshotViewType = @import("telar-core").TabSnapshotView;
const max_panes_per_tab_module = @import("telar-core").max_panes_per_tab;
const pane_resources = @import("operations/panes/pane_resources.zig");
const TabLocation = @import("telar-core").TabLocation;
const WorkspaceSnapshotViewType = @import("telar-core").WorkspaceSnapshotView;
const max_tabs_per_workspace = @import("telar-core").max_tabs_per_workspace;
const WorkspaceTabInputType = @import("workspace/WorkspaceTabInput.zig");
const PaneForeground = @import("telar-core").PaneForeground;
const TabCreatedType = @import("telar-core").TabCreated;
const TabCreationType = @import("model/TabCreation.zig");
const pane_pastes = @import("operations/input/pane_pastes.zig");
const rectSize_module = @import("workspace/multiplexer.zig").rectSize;
const RequestTabCreation = @import("application/tabs/RequestTabCreation.zig");
const create_tab = @import("application/tabs/create_tab.zig");
const TabRenamedType = @import("telar-core").TabRenamed;
const ChangeType = @import("model/types.zig").Change;
const RequestRenameTab = @import("application/tabs/RequestRenameTab.zig");
const rename_tab = @import("application/tabs/rename_tab.zig");
const TabClosedType = @import("telar-core").TabClosed;
const RemovalTriggerType = @import("application/tabs/close_tab.zig").RemovalTrigger;
const TabCloseIntentType = @import("application/tabs/TabCloseIntent.zig");
const close_tab = @import("application/tabs/close_tab.zig");
const ApplyTabRemoval = @import("application/tabs/ApplyTabRemoval.zig");
const TabSnapshotOutcome = enum { applied, ignored };
const TabSnapshotRecovery = enum { coalesced, requested };
const TabCloseOutcome = enum { applied, ignored, exit };

const attached_client_tests = @import("attached_client_tests.zig");
const WorkspaceSelectionTarget = @import("application/workspaces/workspace_handoff.zig").SelectionTarget;
const WorkspaceDeparture = @import("model/WorkspaceDeparture.zig");
const WorkspaceArrival = @import("model/WorkspaceArrival.zig");
const WorkspaceActivation = @import("model/WorkspaceActivation.zig");
const WorkspaceHandoff = @import("application/workspaces/WorkspaceHandoff.zig");
const WorkspacePaneRequest = @import("application/workspaces/PaneRequest.zig");

const WorkspaceSwitchTarget = union(enum) { workspace: core.WorkspaceId, pane: WorkspacePaneRequest };
const WorkspaceSwitchAuthority = enum { requested_departure, canonical_follow };
const WorkspaceRecovery = enum { retried, unrecoverable };

const RequestWorkspaceCreation = @import("application/workspaces/RequestWorkspaceCreation.zig");
const create_workspace = @import("application/workspaces/create_workspace.zig");

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
        .tab_moved => |moved| _ = try tab_moves.apply(self, moved),
        .pane_frame => |frame| _ = try pane_frames.apply(self, frame),
        .pane_cwd => |cwd| _ = try pane_metadata.applyCwd(self, cwd),
        .pane_foreground => |foreground| _ = try pane_metadata.applyForeground(self, foreground),
        .pane_title => |title| _ = try pane_metadata.applyTitle(self, title),
        .pane_progress => |progress| _ = try pane_progress.apply(self, progress),
        .client_command => |command| try self.completeClientCommand(command),
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
        .select_workspace => |position| _ = try self.selectWorkspace(
            .{
                .position = position,
            },
        ),
        .close_pane => _ = try pane_closures.request(self),
        .new_tab => _ = try self.requestTabCreation(
            .{},
        ),
        .new_agent_tab => try self.createAgentTab(),
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
        .close_tab => _ = try self.requestTabClose(),
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

/// Registers correlation before copying the request; failed delivery removes only that registration.
/// Example: `try self.sendRuntimeRequest(delivery);`
pub fn sendRuntimeRequest(self: *AttachedClient, delivery: ConnectionDelivery) !void {
    try self.request_lifecycle.tracker.add(delivery.registration.request_id, delivery.registration.continuation);
    errdefer _ = self.request_lifecycle.tracker.take(delivery.registration.request_id);
    try self.runtime_transport.outbox.push(delivery.message);
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

/// Opens the latest review for any attached pane, preserving an already open edition.
/// Example: `try app.openChangeReview(pane_id);`
pub fn openChangeReview(self: *AttachedClient, pane_id: core.PaneId) !void {
    try self.openChangeReviewSession(pane_id);
    try self.queryChangeReview(if (self.change_review.loaded) self.change_review.snapshot.edition_id else 0);
}

/// Zero requests latest; explicit navigation never replaces a review on new edits.
/// Example: `try app.queryChangeReview(edition_id);`
pub fn queryChangeReview(self: *AttachedClient, edition_id: u64) !void {
    const owner = self.changeReviewOperation(edition_id) catch |err| {
        self.reportChangeReview(@errorName(err));
        return err;
    };

    const request_id = try self.request_lifecycle.nextId();
    try self.request_lifecycle.tracker.add(
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
        _ = self.request_lifecycle.tracker.take(request_id);
        _ = self.failChangeReview(owner, @errorName(err));
        return err;
    };
}

/// Sends one mutation while retaining both the canonical snapshot and local draft.
/// Pass the displayed edition and revision to bind a delayed gesture to its owner.
/// Example: `try app.commandChangeReview(request);`
pub fn commandChangeReview(self: *AttachedClient, request: core.ChangeReviewCommand) !void {
    if (!self.change_review.loaded) {
        self.reportChangeReview("No change review is loaded");
        return error.ChangeReviewNotLoaded;
    }

    const edition_id = if (request.edition_id == 0) self.change_review.snapshot.edition_id else request.edition_id;
    const owner = self.changeReviewOperation(edition_id) catch |err| {
        self.reportChangeReview(@errorName(err));
        return err;
    };

    var outgoing = request;
    outgoing.request_id = try self.request_lifecycle.nextId();
    outgoing.pane_id = owner.pane_id;
    outgoing.pane_generation = owner.pane_generation;
    outgoing.edition_id = edition_id;
    outgoing.session = owner.sessionSlice();
    if (outgoing.expected_revision == 0) {
        outgoing.expected_revision = self.change_review.snapshot.revision;
    }

    try self.request_lifecycle.tracker.add(
        outgoing.request_id,
        .{
            .change_review_command = owner,
        },
    );
    self.beginChangeReview(outgoing.request_id);
    self.sendRuntimeChangeReviewCommand(outgoing) catch |err| {
        _ = self.request_lifecycle.tracker.take(outgoing.request_id);
        _ = self.failChangeReview(owner, @errorName(err));
        return err;
    };
}

/// Drains notices after the view consumes mutation success or failure, so a later
/// refresh can never be mistaken for the acknowledgement of an earlier save.
/// Example: `app.refreshChangeReview();`
pub fn refreshChangeReview(self: *AttachedClient) void {
    if (self.change_review.needsRefresh() and self.change_review.errorSlice().len == 0) {
        self.queryChangeReview(if (self.change_review.loaded) self.change_review.snapshot.edition_id else 0) catch {};
    }
}

/// Resolves the review owner without retaining an address across lifecycle changes.
/// Example: `_ = app.isChangeReviewAttached();`
pub fn isChangeReviewAttached(self: *AttachedClient) bool {
    const owner = self.change_review.owner orelse return false;
    return resolveReviewPane(&self.model, owner) != null;
}

/// Example: `app.closeChangeReview();`
pub fn closeChangeReview(self: *AttachedClient) void {
    self.change_review.close();
    self.model.chrome_revision +%= 1;
}

/// Dispatches one owned target without letting opener failures leave input.
/// Example: `_ = try app.openLink(target);`
pub fn openLink(self: *AttachedClient, target: LinkTarget) !bool {
    const result = switch (target.scheme) {
        .file => open: {
            const path = FilePathType.init(&target) catch |err| {
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
/// Example: `_ = try app.inputLinkPointer(model, event);`
pub fn inputLinkPointer(self: *AttachedClient, model: *MultiplexerModel, event: MouseType) !bool {
    const command: LinkPointerCommand = .{
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
            model,
            event,
            self.geometry().area,
        )
    else
        null;
    const outcome = self.link_pointer.handle(command, target);
    if (outcome.open) |selected| {
        _ = try self.openLink(selected);
    }

    if (outcome.copy) |selected| {
        try self.host_clipboard.set(self.host_clipboard.context, selected.uri());
    }

    return outcome.consumed;
}

/// Completes one host worker and starts the last target queued behind it.
/// Example: `try app.completeLinkOpening(result);`
pub fn completeLinkOpening(self: *AttachedClient, result: anyerror!void) !void {
    if (result) |_| {} else |err| {
        try self.reportLinkFailure(err);
    }

    const next = self.link_opening.complete() orelse return;
    self.link_opener.start(next) catch |err| {
        self.link_opening.schedulingFailed();
        try self.reportLinkFailure(err);
    };
}

/// Reuses a reachable editor in the source tab, otherwise creates a sibling pane.
/// Example: `_ = try app.openMessageFile(pane_id, path);`
pub fn openMessageFile(self: *AttachedClient, pane_id: PaneId, path: FilePathType) !bool {
    self.openEditorPane(pane_id, path) catch |err| {
        try self.reportLinkFailure(err);
        return false;
    };

    return true;
}

/// Starts at most one history request for this connection after frame delivery.
/// Example: `try app.flushAgentHistory();`
pub fn flushAgentHistory(self: *AttachedClient) !void {
    if (self.request_lifecycle.tracker.has(.agent_history)) {
        return;
    }

    const tab = self.model.activeTabModel() orelse return;
    var panes = tab.paneIterator();
    while (panes.next()) |pane| {
        if (pane.history_intent == null) {
            continue;
        }

        var query = (agent_reading.begin(&self.model, pane.id) catch |err| {
            try self.reportAgentHistoryFailure(@errorName(err));
            continue;
        }) orelse continue;
        const operation: AgentHistoryOperation = .{
            .owner = .{
                .pane_id = pane.id,
                .pane_generation = pane.pane_generation,
                .attachment_generation = pane.attachment_generation,
                .location = pane.location,
            },
            .view_generation = query.view_generation,
        };

        query.request_id = self.request_lifecycle.nextId() catch |err| {
            _ = agent_reading.failed(
                &self.model,
                operation,
                @errorName(err),
            );
            try self.reportAgentHistoryFailure(@errorName(err));
            return;
        };

        self.request_lifecycle.tracker.add(
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
            _ = self.request_lifecycle.tracker.take(query.request_id);
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
        try notification_flow.publishNow(
            self,
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
    if (self.request_lifecycle.tracker.hasPane(.agent_prompt, pane_id)) {
        return;
    }

    const intent = self.model.planAgentPrompt(pane_id) orelse return;
    const request_id = try self.request_lifecycle.nextId();
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
    if (self.request_lifecycle.tracker.hasPane(.agent_control, pane_id)) {
        return;
    }

    const request_id = try self.request_lifecycle.nextId();
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
    if (!snapshot.canResume() or index >= snapshot.recent.count or self.request_lifecycle.tracker.hasPane(.agent_control, pane_id) or self.request_lifecycle.tracker.hasPane(.agent_prompt, pane_id)) {
        return;
    }

    const request_id = try self.request_lifecycle.nextId();
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
pub fn approveAgent(self: *AttachedClient, decision: AgentDecision) !void {
    const pending = agentOperation(&self.model, decision.pane_id) orelse return;
    const pane = self.model.agentPane(decision.pane_id) orelse return;
    const thread = pane.agent_thread orelse return;
    const approval = thread.pending_approval orelse return;
    if (approval.id != decision.approval_id or self.request_lifecycle.tracker.hasPane(.agent_control, decision.pane_id)) {
        return;
    }

    const request_id = try self.request_lifecycle.nextId();
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

/// Example: `try app.recoverTabSnapshot(location);`
pub fn recoverTabSnapshot(self: *AttachedClient, location: TabLocation) !TabSnapshotRecovery {
    if (self.request_lifecycle.tracker.has(.tab_snapshot)) {
        return .coalesced;
    }

    try self.requestTabSnapshot(location);
    return .requested;
}

/// Example: `_ = try app.requestTabCreation(command);`
pub fn requestTabCreation(self: *AttachedClient, command: RequestTabCreation) !bool {
    if (self.request_lifecycle.tracker.has(.tab_operation)) {
        return false;
    }

    try create_tab.validateLabel(command.label);
    const plan = self.model.planTabCreation() orelse return false;
    const request_id = try self.request_lifecycle.nextId();
    try self.sendCreateTabRequest(
        .{
            .kind = command.kind,
            .request_id = request_id,
            .workspace = plan.workspace,
            .label = command.label,
            .size = rectSize_module(self.geometry().area) orelse return error.TerminalTooSmall,
            .launch = .{
                .cwd = self.options.cwd,
                .cwd_source = plan.cwd_source,
                .arguments = if (command.kind == .agent) &.{} else if (command.arguments.len != 0) command.arguments else self.options.arguments,
            },
        },
    );

    return true;
}

/// Example: `_ = try app.requestTabRename(command);`
pub fn requestTabRename(self: *AttachedClient, command: RequestRenameTab) !bool {
    if (self.request_lifecycle.tracker.has(.tab_operation)) {
        return false;
    }

    try rename_tab.validateLabel(command.label);
    const location = self.model.tabLocation(command.tab_id) orelse return false;
    const request_id = try self.request_lifecycle.nextId();
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

/// Finishes paste and focus, detaches in pane order, then commits detachment.
/// A failure preserves completed effects; the caller chooses recovery or exit.
/// Example: `try app.detachTab(location);`
pub fn detachTab(self: *AttachedClient, location: TabLocation) !void {
    const plan = try self.model.planTabDetachment(location);
    if (plan.owns_paste) {
        const outcome = try pane_pastes.finish(self);
        std.debug.assert(outcome != .ignored);
    }

    if (plan.owns_reported_focus) {
        const outcome = try pane_focus_reports.clear(self);
        std.debug.assert(outcome == .applied);
    }

    for (plan.slice()) |pane| {
        const pending = self.request_lifecycle.tracker.hasPane(.attachment, pane.pane_id);
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
        _ = self.request_lifecycle.tracker.ignoreAttachment(pane.pane_id);
        try self.graphics.setPaneVisible(pane.pane_id, false);
    }

    try self.model.commitTabDetachment(plan);
}

/// Selects a known inactive workspace only while this connection is idle.
/// Example: `_ = try app.selectWorkspace(.{ .position = 1 });`
pub fn selectWorkspace(self: *AttachedClient, target: WorkspaceSelectionTarget) !bool {
    if (!self.request_lifecycle.tracker.isEmpty()) {
        return false;
    }

    const workspace = switch (target) {
        .position => |position| self.model.workspaceAtPosition(position) orelse return false,
        .workspace => |workspace| workspace,
    };

    if (!self.model.knowsWorkspace(workspace)) {
        return false;
    }

    if (self.model.workspaceLocation()) |current| {
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
pub fn requestWorkspace(self: *AttachedClient, workspace: core.WorkspaceId) !WorkspaceDeparture {
    return self.requestWorkspaceSwitch(
        .{
            .workspace = workspace,
        },
        .requested_departure,
    );
}

/// Opens an exact remote pane with the containing workspace as optional fallback.
/// Example: `_ = try app.requestWorkspacePane(pane_id, workspace_id);`
pub fn requestWorkspacePane(self: *AttachedClient, pane_id: core.PaneId, fallback_workspace: ?core.WorkspaceId) !WorkspaceDeparture {
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

/// Validates a workspace creation and retains its launch parameters until confirmation.
/// Example: `_ = try app.requestWorkspaceCreation(.{ .name = "agents" });`
pub fn requestWorkspaceCreation(self: *AttachedClient, command: RequestWorkspaceCreation) !bool {
    if (!self.request_lifecycle.tracker.isEmpty()) {
        return false;
    }

    try create_workspace.validateName(command.name);
    const cwd_source: ?core.PaneId = if (command.cwd.len == 0)
        self.model.planWorkspaceCreation() orelse return false
    else
        null;
    const request_id = try self.request_lifecycle.nextId();
    try self.sendCreateWorkspaceRequest(
        .{
            .request_id = request_id,
            .size = rectSize_module(self.geometry().area) orelse return error.TerminalTooSmall,
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

/// Registers correlation before copying the request; failed delivery removes only that registration.
/// Example: `try self.sendCreateWorkspaceRequest(request);`
fn sendCreateWorkspaceRequest(self: *AttachedClient, request: core.CreateWorkspace) !void {
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

/// Counts the deliveries needed to detach one tab, including pending attachments.
/// Example: `const required = try app.tabDetachmentCapacity(location);`
fn tabDetachmentCapacity(self: *const AttachedClient, location: TabLocation) !usize {
    const plan = try self.model.planTabDetachment(location);
    var required = @as(usize, @intFromBool(plan.paste_marker_required));
    required += @intFromBool(plan.focus_out_required);
    for (plan.slice()) |pane| {
        required += @intFromBool(pane.attached or self.request_lifecycle.tracker.hasPane(.attachment, pane.pane_id));
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
fn sendTabRenameRequest(self: *AttachedClient, rename: core.RenameTab, continuation: RequestContinuation) !void {
    try self.request_lifecycle.tracker.add(rename.request_id, continuation);
    errdefer _ = self.request_lifecycle.tracker.take(rename.request_id);
    try self.runtime_transport.outbox.pushRename(rename);
    try self.startRuntimeSend();
}

/// Registers correlation before copying the request; failed delivery removes only that registration.
/// Example: `try self.sendCreateTabRequest(request);`
fn sendCreateTabRequest(self: *AttachedClient, request: core.CreateTab) !void {
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
fn sendAgentPromptRequest(self: *AttachedClient, request: core.AgentPrompt, operation: AgentOperation) !void {
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

/// Owns a routed response until its asynchronous send completes. Example: `try self.sendRuntimeClientCompletion(reply);`
fn sendRuntimeClientCompletion(self: *AttachedClient, reply: core.ClientCommand) !void {
    try self.runtime_transport.outbox.pushClientCompletion(reply);
    try self.startRuntimeSend();
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
            try plugin_invocations.run(self, reply);
        },
        .plugin_disable => {
            try plugin_toggles.disable(self, reply);
        },
        .plugin_enable => {
            try plugin_toggles.enable(self, reply);
        },
        .plugin_get => {
            try plugin_queries.get(self, reply);
        },
        .plugin_list => {
            try plugin_queries.list(self, reply);
        },
        .config_show => {
            try config_queries.show(self, reply);
        },
        .config_reload => {
            try config_reloads.request(self);
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
            const tab = self.model.activeTabModelConst() orelse return error.NoActiveTab;
            const pane = tab.findConst(selection.pane_id) orelse return error.PaneNotFound;
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
            const tab = self.model.activeTabModelConst() orelse return error.NoActiveTab;
            const pane = tab.findConst(pane_id) orelse return error.PaneNotFound;
            if (!pane.attached or copy_modes.active(self)) {
                return error.PaneViewportUnavailable;
            }

            if (pane.kind == .agent) {
                _ = self.model.scrollAgentThread(pane_id, @floatFromInt(delta));
            } else {
                _ = try pane_viewports.apply(
                    self,
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
            const direction = std.meta.stringToEnum(LayoutDirection, reply.text()) orelse return error.InvalidPaneDirection;
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
            if (try pane_closures.request(
                self,
            ) == null) {
                return error.PaneClosureUnavailable;
            }

            reply.status = .admitted;
        },
        .pane_split => {
            const axis = std.meta.stringToEnum(SplitAxis, reply.text()) orelse return error.InvalidSplitAxis;
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

            if (try tab_selections.select(
                self,
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

            if (self.model.workspaceLocation()) |location| {
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
            try self.host_clipboard.set(self.host_clipboard.context, reply.text());
            reply.length = 0;
            reply.status = .admitted;
        },
        .client_open_link => {
            const target = try LinkTarget.init(reply.text());
            if (!try self.openLink(target)) {
                return error.LinkOpeningUnavailable;
            }

            reply.length = 0;
            reply.status = .admitted;
        },
        .notification_dismiss => {
            if (try notification_flow.dismissNow(self, @enumFromInt(reply.target_id)) == null) {
                return error.NotificationNotFound;
            }

            reply.status = .applied;
        },
        .client_copy_mode => {
            if (!copy_modes.active(self) and !copy_modes.enter(self)) {
                return error.CopyModeUnavailable;
            }

            reply.status = .applied;
        },
        .client_open_history => {
            if (!try history_palettes.begin(self)) {
                return error.ClientPromptUnavailable;
            }

            reply.status = .admitted;
        },
        .client_open_goto => {
            if (!name_prompts.beginGotoPicker(self)) {
                return error.ClientPromptUnavailable;
            }

            reply.status = .applied;
        },
        .workspace_list_collapse => {
            if (self.model.setWorkspaceListCollapsed(true) != null) {
                self.chrome.setWorkspaceListCollapsed(true);
            }

            reply.status = .applied;
        },
        .workspace_list_expand => {
            if (self.model.setWorkspaceListCollapsed(false) != null) {
                self.chrome.setWorkspaceListCollapsed(false);
            }

            reply.status = .applied;
        },
        .sidebar_resize => {
            const width = std.math.cast(u16, reply.value) orelse return error.InvalidWidth;
            if (width == 0) {
                return error.InvalidWidth;
            }

            _ = try sidebar_toggles.resize(
                self,
                .{
                    .exact = width,
                },
            );
            try self.writeCommandSidebarState(reply);
        },
        .sidebar_hide => {
            if (self.model.sidebarVisible()) {
                _ = try sidebar_toggles.toggle(
                    self,
                );
            }

            try self.writeCommandSidebarState(reply);
        },
        .sidebar_show => {
            if (!self.model.sidebarVisible()) {
                _ = try sidebar_toggles.toggle(
                    self,
                );
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
            if (!self.model.hostCapabilities().agent_panes) {
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
    const tab = self.model.activeTabModelConst() orelse return error.NoActiveTab;
    _ = tab.findConst(pane_id) orelse return error.PaneNotFound;
    if (tab.layout.focused() == pane_id) {
        return;
    }

    if (!try self.focusPane(
        .{
            .pane_id = pane_id,
        },
    )) {
        return error.PaneFocusUnavailable;
    }
}

fn selectCommandTabOffset(self: *AttachedClient, reply: *core.ClientCommand, offset: isize) !void {
    if (self.model.activeTabLocation() == null) {
        return error.NoActiveTab;
    }

    if (self.request_lifecycle.tracker.has(.tab_snapshot)) {
        return error.ClientBusy;
    }

    const change = try tab_selections.select(
        self,
        .{
            .target = .{
                .offset = offset,
            },
        },
    );
    reply.status = if (change == null) .applied else .admitted;
}

fn writeCommandSidebarState(self: *const AttachedClient, reply: *core.ClientCommand) !void {
    reply.value = self.model.sidebarWidth();
    try reply.setText(if (self.model.sidebarVisible()) "visible" else "hidden");
    reply.status = .applied;
}

/// Encodes the active layout with stable pane identities into the bounded reply.
fn writeCommandLayout(self: *const AttachedClient, reply: *core.ClientCommand) !void {
    const tab = self.model.workspace.activeConst() orelse return error.NoActiveTab;
    const focused = tab.model.layout.focused() orelse return error.NoFocusedPane;
    var nodes: [core.max_client_layout_nodes]core.ClientLayoutNode = undefined;
    const tabs = [_]core.ClientTabLayout{
        .{
            .location = tab.location,
            .focused_pane = focused,
            .fullscreen = tab.model.layout.isFullscreen(),
            .workspace_active = true,
            .nodes = tab.model.layout.clientLayoutNodes(&nodes),
        },
    };

    var buffer: [core.ClientCommand.capacity / 2]u8 = undefined;
    const encoded = try core.encodeClientLayoutSnapshot(
        &buffer,
        .{
            .restored = true,
            .sidebar_visible = self.model.sidebarVisible(),
            .sidebar_width = self.model.sidebarWidth(),
            .workspace_list_collapsed = self.model.workspaceListCollapsed(),
            .active_tab = tab.location,
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
    if (!self.request_lifecycle.tracker.isEmpty()) {
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

    try pane_focus.applyLayout(
        self,
        .{
            .location = tab.location,
            .layout = try WorkspaceLayout.fromClientLayout(tab),
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

    _ = try self.requestTabCreation(
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

    _ = try self.recoverTabSnapshot(attachment.location);
    return true;
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
        try self.identifyOpenedPane(opened);
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
    const size = rectSize_module(self.geometry().area) orelse return error.TerminalTooSmall;
    const activation = try self.model.arriveWorkspace(workspaceArrival(
        &self.navigation_history,
        opened,
        size,
    ));
    try self.activateWorkspace(activation);
}

fn createOpenedWorkspace(self: *AttachedClient, confirmation: WorkspaceCreationType) !void {
    if (!confirmation.opened.created) {
        return error.UnexpectedRequest;
    }

    const replacement = try self.model.replaceWorkspace(workspaceArrival(
        &self.navigation_history,
        confirmation.opened,
        confirmation.requested_size,
    ));
    self.releaseWorkspace(&replacement.departure);
    try self.activateWorkspace(replacement.activation);
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

    _ = self.editor_open.complete(failure.request_id);

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

/// Copies borrowed wire content before the next receive can overwrite it.
fn applyChangeReview(self: *AttachedClient, response: core.ChangeReviewSnapshotView) !bool {
    const continuation = self.request_lifecycle.tracker.take(response.request_id) orelse return false;
    const owner: ChangeReviewOperation = switch (continuation) {
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
    if (self.change_review.pending != request_id) {
        return;
    }

    const owner = self.change_review.owner orelse return;
    _ = self.failChangeReview(owner, "The pane was detached; reopen its review");
}

/// Opens any attached pane, including an agent launched in an ordinary terminal.
fn openChangeReviewSession(self: *AttachedClient, pane_id: core.PaneId) !void {
    const pane = findReviewPane(&self.model, pane_id) orelse return error.ChangeReviewPaneUnavailable;
    self.change_review.open(
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
fn changeReviewOperation(self: *AttachedClient, edition_id: u64) !ChangeReviewOperation {
    if (self.change_review.session_changed) {
        return error.RetiredChangeReviewSession;
    }

    if (self.change_review.pending != null) {
        return error.ChangeReviewRequestPending;
    }

    var owner = self.change_review.owner orelse return error.ChangeReviewClosed;
    if (resolveReviewPane(&self.model, owner) == null) {
        return error.ChangeReviewPaneUnavailable;
    }

    owner.edition_id = edition_id;
    if (self.change_review.loaded) {
        try owner.setSession(self.change_review.snapshot.session);
    }

    return owner;
}

fn beginChangeReview(self: *AttachedClient, request_id: core.RequestId) void {
    self.change_review.begin(request_id);
    self.model.chrome_revision +%= 1;
}

/// Applies a reply only while both the attachment and view still exist.
fn applyChangeReviewResponse(self: *AttachedClient, owner: ChangeReviewOperation, response: core.ChangeReviewSnapshotView) !bool {
    if (resolveReviewPane(&self.model, owner) == null) {
        _ = self.failChangeReview(owner, "The pane was detached; reopen its review");
        return false;
    }

    const applied = try self.change_review.apply(owner, response);
    if (applied) {
        self.model.chrome_revision +%= 1;
    }

    return applied;
}

/// Retains pane availability even when its review is closed, and refreshes an open view.
fn changeReviewChanged(self: *AttachedClient, notification: core.ChangeReviewChanged) bool {
    const pane = findReviewPane(&self.model, notification.pane_id) orelse return false;
    const availability_changed = pane.applyChangeReview(notification);
    const review_changed = if (self.change_review.owner) |owner| resolveReviewPane(&self.model, owner) != null and self.change_review.changed(notification) else false;
    if (!availability_changed and !review_changed) {
        return false;
    }

    self.model.chrome_revision +%= 1;
    return true;
}

/// Retains review content and exposes failure without clearing adapter drafts.
fn failChangeReview(self: *AttachedClient, owner: ChangeReviewOperation, message: []const u8) bool {
    if (!self.change_review.failed(owner, message)) {
        return false;
    }

    self.model.chrome_revision +%= 1;
    return true;
}

fn reportChangeReview(self: *AttachedClient, message: []const u8) void {
    self.change_review.report(message);
    self.model.chrome_revision +%= 1;
}

fn findReviewPane(model: *ModelType, pane_id: core.PaneId) ?*Pane {
    const pane = model.workspace.findPane(pane_id) orelse return null;
    return if (pane.attached and pane.pane_generation != 0) pane else null;
}

fn resolveReviewPane(model: *ModelType, owner: ChangeReviewOperation) ?*const Pane {
    const pane = findReviewPane(model, owner.pane_id) orelse return null;
    return if (pane.pane_generation == owner.pane_generation and pane.attachment_generation == owner.attachment_generation) pane else null;
}

fn linkTargetAt(model: *MultiplexerModel, event: MouseType, area: RectType) ?LinkTarget {
    const plan = model.planPaneMouse(event, area) orelse return null;
    const pane = model.findConst(plan.pane_id) orelse return null;

    return extract_module(
        &pane.buffer,
        pane.scroll,
        .{
            .x = event.x - plan.content.x,
            .y = pane.scroll.offset + event.y - plan.content.y,
        },
    );
}

fn openLinkFile(self: *AttachedClient, path: FilePathType) !void {
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

fn openExternalLink(self: *AttachedClient, target: LinkTarget) !void {
    switch (self.link_opening.request(target)) {
        .queued => {},
        .start => |selected| self.link_opener.start(selected) catch |err| {
            self.link_opening.schedulingFailed();

            return err;
        },
    }
}

fn reportLinkFailure(self: *AttachedClient, err: anyerror) !void {
    try notification_flow.publishNow(
        self,
        .{
            .level = .warning,
            .title = "Could not open link",
            .message = @errorName(err),
        },
    );
}

fn openEditorPane(self: *AttachedClient, pane_id: PaneId, path: FilePathType) !void {
    const editor = self.editorExecutable();
    if (editor.len == 0) {
        return error.EditorUnavailable;
    }

    const model = self.model.activeTabModel() orelse return error.PaneNotFound;
    const source = model.findConst(pane_id) orelse return error.PaneNotFound;
    var request: core.OwnedEditorOpen = .{
        .request_id = .none,
        .pane_id = pane_id,
        .pane_generation = source.pane_generation,
    };

    try request.setTarget(editor, path.slice());
    const kind = core.editor.identify(editor);
    var reusable = false;
    if (kind != .unsupported and source.pane_generation != 0) {
        var panes = model.paneConstIterator();
        while (panes.next()) |pane| {
            reusable = reusable or core.editor.identify(pane.foregroundName()) == kind;
        }
    }

    if (!reusable) {
        return self.splitEditorPane(request);
    }

    request.request_id = try self.request_lifecycle.nextId();
    try self.editor_open.begin(request);
    errdefer _ = self.editor_open.complete(request.request_id);
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
    const request = self.editor_open.complete(reply.request_id) orelse return;
    const continuation = self.request_lifecycle.tracker.take(reply.request_id) orelse return;
    if (continuation != .editor_open) {
        return;
    }

    const operation = continuation.editor_open;
    const model = self.model.activeTabModel() orelse return;
    const source = model.findConst(operation.pane_id) orelse return;
    if (source.pane_generation != operation.pane_generation or source.attachment_generation != operation.attachment_generation or !std.meta.eql(source.location, operation.location)) {
        return;
    }

    switch (reply.outcome) {
        .unavailable => self.splitEditorPane(request) catch |err| try self.reportLinkFailure(err),
        .failed => try self.reportLinkFailure(error.EditorOpenFailed),
        .opened => {
            const pane = model.findConst(reply.pane_id) orelse return;
            if (pane.pane_generation != reply.pane_generation) {
                return;
            }

            _ = try pane_focus.apply(
                self,
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
    const continuation = self.request_lifecycle.tracker.take(response.request_id) orelse return false;

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
    try notification_flow.publishNow(
        self,
        .{
            .level = .failure,
            .title = "Could not load messages",
            .message = message,
        },
    );
}

fn createAgentTab(self: *AttachedClient) !void {
    if (!self.model.hostCapabilities().agent_panes) {
        try notification_flow.publishNow(
            self,
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
    if (self.request_lifecycle.tracker.hasPane(.agent_query, pane_id)) {
        return;
    }

    const request_id = try self.request_lifecycle.nextId();
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
    const continuation = self.request_lifecycle.tracker.take(reply.request_id) orelse return error.UnexpectedControlReply;
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

fn agentOperation(model: *const ModelType, pane_id: core.PaneId) ?AgentOperation {
    const pane = model.agentPane(pane_id) orelse return null;
    return .{
        .pane_id = pane_id,
        .pane_generation = pane.pane_generation,
        .attachment_generation = pane.attachment_generation,
        .location = pane.location,
    };
}

fn applyTabSnapshot(self: *AttachedClient, snapshot: TabSnapshotViewType) !TabSnapshotOutcome {
    const continuation = self.request_lifecycle.tracker.take(snapshot.request_id) orelse
        return error.UnexpectedTabSnapshot;
    const expected_location = switch (continuation) {
        .tab_snapshot => |location| location,
        .ignored => return .ignored,
        else => return error.UnexpectedTabSnapshot,
    };

    if (!std.meta.eql(expected_location, snapshot.location)) {
        return error.UnexpectedTabSnapshot;
    }

    var pane_ids: [max_panes_per_tab_module]PaneId = undefined;
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
        self.request_lifecycle.tracker.ignorePane(pane_id);
        pane_resources.release(self, pane_id);
    }

    if (reconciliation.active) {
        const tab = self.model.workspace.find(reconciliation.location.tab_id) orelse return error.StaleTabReconciliation;
        try self.synchronizeActivePane();
        try self.resizeAttachedPanes(&tab.model, reconciliation.area);
        try self.attachVisiblePanes(tab, reconciliation.area);
    }

    return .applied;
}

fn applyWorkspaceSnapshot(self: *AttachedClient, snapshot: WorkspaceSnapshotViewType) !void {
    const continuation = self.request_lifecycle.tracker.take(snapshot.request_id) orelse
        return error.UnexpectedWorkspaceSnapshot;
    const expected_workspace = switch (continuation) {
        .workspace_snapshot => |workspace| workspace,
        .rename_workspace => |workspace| workspace,
        else => return error.UnexpectedWorkspaceSnapshot,
    };

    if (!std.meta.eql(expected_workspace, snapshot.workspace)) {
        return error.UnexpectedWorkspaceSnapshot;
    }

    var tabs: [max_tabs_per_workspace]WorkspaceTabInputType = undefined;
    var foregrounds: [max_tabs_per_workspace][max_panes_per_tab_module]PaneForeground = undefined;
    var tab_count: usize = 0;
    var iterator = snapshot.tabs();
    while (try iterator.next()) |tab| {
        if (tab_count == tabs.len) {
            return error.TooManyTabs;
        }

        var names = tab.foregrounds();
        var name_count: usize = 0;
        while (try names.next()) |foreground| {
            if (name_count == max_panes_per_tab_module) {
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
        self.request_lifecycle.tracker.ignoreTab(location.tab_id);
    }

    for (reconciliation.removed_panes.slice()) |pane_id| {
        pane_resources.release(self, pane_id);
    }

    const active = self.model.workspace.active() orelse return error.StaleWorkspaceReconciliation;
    if (reconciliation.active_tab_changed) {
        _ = self.model.forgetReportedPaneFocus();
        var panes = active.model.paneIterator();
        while (panes.next()) |pane| {
            try self.graphics.setPaneVisible(pane.id, true);
        }

        try self.synchronizeActivePane();
    }

    if (self.request_lifecycle.tracker.has(.tab_snapshot)) {
        return;
    }

    if (reconciliation.active_tab_changed or !reconciliation.active_snapshot_loaded) {
        try self.requestTabSnapshot(reconciliation.active);
        return;
    }

    try self.resizeAttachedPanes(&active.model, self.geometry().area);
}

fn completeTabCreation(self: *AttachedClient, created: TabCreatedType) !TabCreationType {
    const continuation = self.request_lifecycle.tracker.take(created.request_id) orelse
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

fn completeTabRename(self: *AttachedClient, renamed: TabRenamedType) !ChangeType {
    const continuation = self.request_lifecycle.tracker.take(renamed.request_id) orelse
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
    if (self.request_lifecycle.tracker.has(.tab_operation)) {
        return false;
    }

    const location = self.model.activeTabLocation() orelse return false;
    const required = try self.tabDetachmentCapacity(location);
    try self.request_lifecycle.ensureCanStart(2);
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

fn recoverTabClose(self: *AttachedClient, location: TabLocation) !bool {
    const active = self.model.activeTabLocation() orelse return false;
    if (!std.meta.eql(active, location)) {
        return false;
    }

    _ = try self.recoverTabSnapshot(location);
    return true;
}

fn completeTabClose(self: *AttachedClient, closed: TabClosedType) !TabCloseOutcome {
    const trigger: RemovalTriggerType = if (closed.request_id == .none)
        .lifecycle
    else requested: {
        const continuation = self.request_lifecycle.tracker.take(closed.request_id) orelse
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

    const command: ApplyTabRemoval = .{
        .location = closed.location,
        .workspace_removed = closed.workspace_closed,
        .previous_workspace = closed.previous_workspace,
        .trigger = trigger,
    };

    try close_tab.validateWorkspaceTransition(command);
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
            self.request_lifecycle.tracker.ignoreTab(stale.location.tab_id);
            return .applied;
        },
        .removed => |removed| removed,
    };

    self.request_lifecycle.tracker.ignoreTab(removal.removed.tab_id);
    for (removal.panes.slice()) |pane_id| {
        pane_resources.release(self, pane_id);
    }

    if (removal.was_active) {
        _ = self.model.forgetReportedPaneFocus();
        if (removal.active) |location| {
            const active = self.model.workspace.find(location.tab_id) orelse return error.StaleTabRemoval;
            var panes = active.model.paneIterator();
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

    self.navigation_history.forget(removal.removed.workspace);
    const previous = command.previous_workspace orelse return .exit;
    _ = try self.requestWorkspaceSwitch(
        .{
            .workspace = previous,
        },
        .canonical_follow,
    );
    return .applied;
}

fn sendTabClose(self: *AttachedClient, intent: TabCloseIntentType) !void {
    const request_id = try self.request_lifecycle.nextId();

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
fn requestWorkspaceSwitch(self: *AttachedClient, target: WorkspaceSwitchTarget, authority: WorkspaceSwitchAuthority) !WorkspaceDeparture {
    const size = rectSize_module(self.geometry().area) orelse return error.TerminalTooSmall;
    const command: WorkspaceHandoff = switch (target) {
        .workspace => |workspace| selected: {
            const bookmark = self.navigation_history.find(
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
            if (!self.request_lifecycle.tracker.isEmpty()) {
                return error.WorkspaceSwitchWhileRequestPending;
            }
        },
        .canonical_follow => {
            if (self.model.workspaceLocation() != null) {
                return error.WorkspaceStillActive;
            }
        },
    }

    try self.request_lifecycle.ensureCanStart(2);
    var required: usize = 1;
    var tabs = self.model.workspace.tabIterator();
    while (tabs.next()) |tab| {
        required += try self.tabDetachmentCapacity(tab.location);
    }

    if (required > self.runtime_transport.outbox.availableCapacity()) {
        return error.ClientOutboxFull;
    }

    tabs = self.model.workspace.tabIterator();
    while (tabs.next()) |tab| {
        self.detachTab(tab.location) catch |err| {
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

    self.navigation_history.forget(
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
            .size = rectSize_module(self.geometry().area) orelse return error.TerminalTooSmall,
        },
    );
    return .retried;
}

/// Correlates the open before its owned message enters the runtime outbox.
fn sendWorkspaceOpen(self: *AttachedClient, command: WorkspaceHandoff) !void {
    const request_id = try self.request_lifecycle.nextId();
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
fn workspaceArrival(history: *const HistoryType, opened: OpenedPaneType, size: core.TerminalSize) WorkspaceArrival {
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
fn releaseWorkspace(self: *AttachedClient, departure: *const WorkspaceDeparture) void {
    if (departure.bookmark) |bookmark| {
        self.navigation_history.remember(
            .{
                .location = bookmark.location,
                .pane_id = bookmark.pane_id,
                .tab_layout = bookmark.tab_layout,
            },
        );
    }

    for (departure.panes.slice()) |pane_id| {
        pane_resources.release(self, pane_id);
    }

    _ = self.model.forgetReportedPaneFocus();
}

/// Validates the committed root before resuming input and requesting canonical snapshots.
fn activateWorkspace(self: *AttachedClient, activation: WorkspaceActivation) !void {
    const active = self.model.workspace.activeConst() orelse return error.StaleWorkspaceActivation;
    const root = active.model.findConst(activation.pane_id) orelse return error.StaleWorkspaceActivation;
    const version = self.model.version();
    if (!std.meta.eql(active.location, activation.location) or
        active.model.pane_count != 1 or
        active.model.layout.focused() != activation.pane_id or
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
    try self.host_input_source.resumeRead();
    try self.requestWorkspaceSnapshot(activation.location.workspace);
    try self.requestTabSnapshot(activation.location);
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
