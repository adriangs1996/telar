const agent_options = @import("../panes/agent_options.zig");
const core = @import("telar-core");
const model_data = @import("../model.zig");
const workspace_list_rejection = @import("../application/workspaces/workspace_list_snapshot.zig");
const EntryInputType = @import("../workspace/EntryInput.zig");
const AgentPromptIntent = @import("../application/agents/AgentPromptIntent.zig");
const AgentPane = @import("../panes/Pane.zig");
const model_namespace = @import("model_namespace.zig");
const Tabs = @import("../workspace/Tabs.zig");
const Config = @import("Config.zig");
const Panes = @import("../panes/Panes.zig");
const LayoutSnapshot = @import("../workspace/LayoutSnapshot.zig");
const PendingLayoutRestore = @import("../workspace/PendingLayoutRestore.zig");
const tab_layout = @import("../workspace/tab_layout.zig");
const tab_label = @import("../workspace/tab_label.zig");
const tab_creation = @import("../workspace/tab_creation.zig");
const tab_removal = @import("../workspace/tab_removal.zig");
const tab_move = @import("../workspace/tab_move.zig");
const tab_rename = @import("../workspace/tab_rename.zig");
const tab_selection = @import("../workspace/tab_selection.zig");
const tab_snapshot_reconciliation = @import("../workspace/tab_snapshot_reconciliation.zig");
const workspace_reconciliation = @import("../workspace/workspace_reconciliation.zig");
const workspace_handoff = @import("../workspace/workspace_handoff.zig");
const pane_split = @import("../workspace/pane_split.zig");
const presentation_delivery = @import("../panes/presentation_delivery.zig");
const LayoutsType = @import("../workspace/SavedLayouts.zig");
const ClipboardCaptureState = @import("ClipboardCaptureState.zig");
const PluginExecutionState = @import("PluginExecutionState.zig");
const HostState = @import("HostState.zig");
const HistoryPaletteState = @import("HistoryPaletteState.zig");
const SuggestionState = @import("SuggestionState.zig");
const WorkspaceListSnapshot = @import("../workspace/WorkspaceListSnapshot.zig");
const SnapshotType = @import("../agents/AgentSnapshot.zig");
const SystemMetricsType = @import("SystemMetrics.zig");
const StateType = @import("../bars/State.zig");
const ReportedPaneFocusType = @import("ReportedPaneFocus.zig");
const std = @import("std");
const InitialClientStateType = @import("InitialClientState.zig");
const VersionType = @import("Version.zig");
const PresentationCommitType = @import("../panes/PresentationCommit.zig");
const PluginExecutionType = @import("PluginExecution.zig");
const ConfigurationInputType = @import("ConfigurationInput.zig");
const BarUpdateInputType = @import("BarUpdateInput.zig");
const BarUpdateCommitType = @import("BarUpdateCommit.zig");
const WorkspaceListCollapseType = @import("WorkspaceListCollapse.zig");
const SnapshotInputType = @import("../workspace/WorkspaceListInput.zig");
const WorkspaceListCommitType = @import("WorkspaceListCommit.zig");
const SystemMetricsCommitType = @import("SystemMetricsCommit.zig");
const AgentsSnapshotInput = @import("../agents/SnapshotInput.zig");
const PaneFocusReportTransitionType = @import("PaneFocusReportTransition.zig");
const PaneMetadataCommitType = @import("PaneMetadataCommit.zig");
const PointerPressType = @import("../input/PointerPress.zig");
const CopyModeProjectionType = @import("CopyModeProjection.zig");
const CopyModePlanType = @import("CopyModePlan.zig");
const cells_module = @import("../links/cells.zig");
const CopyModeCommitType = @import("CopyModeCommit.zig");
const CopyModeFrameType = @import("CopyModeFrame.zig");
const TabCreationPlanType = @import("TabCreationPlan.zig");
const WorkspaceReplacementType = @import("WorkspaceReplacement.zig");
const WorkspaceActivationSeedType = @import("WorkspaceActivationSeed.zig");
const WorkspaceSnapshotInput = @import("../workspace/WorkspaceSnapshotInput.zig");
const WorkspaceReconciliationType = @import("WorkspaceReconciliation.zig");
const PaneSnapshot = @import("../workspace/PaneSnapshot.zig");
const TabReconciliationType = @import("TabReconciliation.zig");
const TabDetachmentPlanType = @import("TabDetachmentPlan.zig");
const multiplexer_module = @import("../workspace/multiplexer.zig");
const CommitPaneSplitType = @import("CommitPaneSplit.zig");
const PaneSplitCommitStateType = @import("PaneSplitCommitState.zig");
const RecoverPaneSplitType = @import("RecoverPaneSplit.zig");
const RenameTabType = @import("RenameTab.zig");
const NewTabType = @import("NewTab.zig");
const RemoveTabType = @import("RemoveTab.zig");
const Model = @This();

gpa: std.mem.Allocator,
/// Settings adopted from the active configuration generation.
config: Config = .{},
startup: model_data.StartupState = .{},
request_lifecycle: model_data.RequestLifecycle = .{},
/// Retained tab layouts sent to the runtime for reconnect.
client_layouts: model_data.ClientLayoutsState = .{},
navigation_history: model_data.NavigationHistory = .{},
sound_playback: model_data.SoundPlayback = .{ .configuration = .{} },
clipboard_capture_resources: model_data.CaptureResources = .{},
link_opening: model_data.Opening = .{},
link_pointer: model_data.Pointer = .{},
change_review: model_data.ChangeReviewSession = .{},
sidebar_animation_scheduler: core.DeadlineScheduler = .{},
notification_scheduler: core.DeadlineScheduler = .{},
bar_updates: model_data.BarUpdatesState = .{},
favicons: model_data.FaviconsState = .{},
/// Application key leases, owned by routing rather than by the host reader.
input_leases: model_data.key_routing.Leases = .{},
editor_open: model_data.EditorOpening = .{},
tabs: Tabs = .{},
panes: Panes = .{},
/// The runtime workspace this client shows; null before arrival and after
/// departure.
workspace: ?core.WorkspaceLocation = null,
workspace_name: [core.max_workspace_name_bytes]u8 = undefined,
workspace_name_len: u16 = 0,
pane_gaps: bool = true,
/// A retained client layout applied when its tab's next snapshot arrives.
pending_layout_restore: ?PendingLayoutRestore = null,
/// Geometry of the most recently queried tab, see `tab_layout.snapshot`.
layout_snapshot: LayoutSnapshot = .{},
layout_snapshot_tab: core.TabId = .invalid,
saved_layouts: LayoutsType = .{},
clipboard: ClipboardCaptureState = .{},
plugins: PluginExecutionState = .{},
host: HostState,
name_prompt: model_data.NamePromptState = .{},
history_palette: HistoryPaletteState = .{},
suggestion: SuggestionState = .{},
path_completion: model_data.PathCompletionState = .{},
workspace_revision: u64 = 0,
configuration_generation: u64 = 0,
window_title_template: [model_data.state_types.max_window_title_template_bytes]u8 = undefined,
window_title_template_len: u8 = 0,
configuration_revision: u64 = 0,
client_diagnostic: model_data.Diagnostic = .{},
diagnostic_revision: u64 = 0,
workspace_list_snapshot: WorkspaceListSnapshot = .{},
workspace_list_revision: u64 = 0,
agent_snapshot: SnapshotType = .{},
agent_revision: u64 = 0,
/// Operational state: the focused agent whose `done` status this client
/// already acknowledged. It carries no presentation revision.
acknowledged_agent: ?model_data.AgentKey = null,
sidebar_animation_frame: u8 = 0,
sidebar_animation_revision: u64 = 0,
proxy_tls_active: bool = false,
proxy_tls_scope: core.ProxyScope = .exact,
proxy_system_trusted: bool = false,
proxy_status_revision: u64 = 0,
system_metrics: ?SystemMetricsType = null,
system_metrics_revision: u64 = 0,
bars: StateType = .{},
bars_revision: u64 = 0,
notification_center: model_data.Center = .{},
notifications_revision: u64 = 0,
tabs_revision: u64 = 0,
active_tab_revision: u64 = 0,
panes_revision: u64 = 0,
sidebar_visible: bool = true,
sidebar_width: u16 = model_data.sidebar.default_width,
workspace_list_collapsed: bool = false,
chrome_revision: u64 = 0,
copy_state: ?model_data.State = null,
selection_clicks: core.ClickTracker = .{},
selection_click_pane: ?core.PaneId = null,
selection_gesture: ?core.PaneId = null,
copy_revision: u64 = 0,
reported_pane_focus: ?ReportedPaneFocusType = null,
next_attachment_generation: u64 = 1,
pane_paste: ?model_data.PanePasteSession = null,
frame_revision: u64 = 0,
pane_metadata_revision: u64 = 0,
pane_foreground_revision: u64 = 0,
pane_progress_revision: u64 = 0,
pane_graphics_revision: u64 = 0,
viewport_revision: u64 = 0,

/// Creates the client model with the configured pane appearance.
///
/// ```zig
/// var model = Model.init(gpa, true);
/// ```
pub fn init(gpa: std.mem.Allocator, pane_gaps: bool) Model {
    return initWithState(gpa, .{ .pane_gaps = pane_gaps });
}

/// Creates the client model at one already active configuration generation.
///
/// ```zig
/// var model = Model.initWithConfiguration(gpa, true, 1);
/// ```
pub fn initWithConfiguration(gpa: std.mem.Allocator, pane_gaps: bool, generation: u64) Model {
    return initWithState(gpa, .{
        .pane_gaps = pane_gaps,
        .configuration_generation = generation,
    });
}

/// Creates the client model from its complete initial semantic state.
///
/// ```zig
/// var model = Model.initWithState(gpa, initial);
/// ```
pub fn initWithState(gpa: std.mem.Allocator, initial: InitialClientStateType) Model {
    var self: Model = undefined;
    self.initInto(gpa, initial);
    return self;
}

/// Initializes the final destination without copying the reserved workspace slots.
/// Example: `model.initInto(gpa, initial);`
pub fn initInto(self: *Model, gpa: std.mem.Allocator, initial: InitialClientStateType) void {
    initial.host_size.validate() catch unreachable;
    const cell_size = initial.host_capabilities.cellSize(
        initial.host_size.cols,
        initial.host_size.rows,
    );
    std.debug.assert(initial.host_size.cell_width_px == cell_size.width);
    std.debug.assert(initial.host_size.cell_height_px == cell_size.height);

    self.* = .{
        .gpa = gpa,
        .config = initial.config,
        .pane_gaps = initial.pane_gaps,
        .configuration_generation = initial.configuration_generation,
        .bars = .init(initial.bars),
        .host = .{ .host_size = initial.host_size, .host_capabilities = initial.host_capabilities },
        .sidebar_width = @max(model_data.sidebar.minimum_width, initial.sidebar_width),
    };

    std.debug.assert(initial.window_title.len <= self.window_title_template.len);
    @memcpy(self.window_title_template[0..initial.window_title.len], initial.window_title);
    self.window_title_template_len = @intCast(initial.window_title.len);
}

/// Releases all semantic workspace state owned by the model.
///
/// ```zig
/// defer model.deinit();
/// ```
pub fn deinit(model: *Model) void {
    model.history_palette.deinit();
    model.clipboard_capture_resources.deinit(model.gpa);
    workspace_handoff.clear(model);
    model.saved_layouts = .{};
}

/// Installs validated reconnect layouts before the initial pane arrives.
/// Example: `model.restoreClientLayouts(layouts);`.
pub fn restoreClientLayouts(model: *Model, layouts: LayoutsType) void {
    model.saved_layouts = layouts;
}

/// Flips the focused pane between its terminal cells and its thread view and
/// reports the surface now shown. Absent or empty layouts leave every version
/// intact.
///
/// ```zig
/// const surface = model.togglePaneSurface() orelse return;
/// ```
pub fn togglePaneSurface(model: *Model) ?core.PaneSurface {
    const slot = model.tabs.activeSlot() orelse return null;
    const layout = &model.tabs.layout[slot];
    const focused = layout.focused() orelse return null;
    if (model.panes.findInConst(model.tabs.location[slot].tab_id, focused)) |pane| {
        if (pane.kind == .agent) {
            return .thread;
        }
    }

    const next: core.PaneSurface = switch (layout.surface(focused)) {
        .terminal => .thread,
        .thread => .terminal,
    };
    if (!layout.setSurface(focused, next)) {
        return null;
    }

    model.panes_revision +%= 1;
    return next;
}

/// Captures an attached agent pane without granting mutation authority.
/// Example: `const pane = model.agentPane(pane_id) orelse return;`
pub fn agentPane(model: *const Model, pane_id: core.PaneId) ?*const AgentPane {
    const pane = model.panes.findConst(pane_id) orelse return null;
    return if (pane.attached and pane.kind == .agent) pane else null;
}

/// Installs runtime pane identity after a correlated attachment succeeds.
/// Example: `_ = model.identifyPane(opened);`
pub fn identifyPane(model: *Model, opened: core.PaneOpened) bool {
    const pane = model.panes.find(opened.pane_id) orelse return false;
    if (!pane.attached or !std.meta.eql(pane.location, opened.location)) {
        return false;
    }

    const slot = model.tabs.find(pane.location.tab_id) orelse return false;
    const changed = pane.identify(opened.kind, opened.pane_generation);
    const surface_changed = if (pane.kind == .agent) model.tabs.layout[slot].setSurface(pane.id, .thread) else false;

    if (changed or surface_changed) {
        model.panes_revision +%= 1;
    }

    return true;
}

/// Copies canonical conversation state only for the current runtime pane.
/// Example: `_ = try model.applyAgentThread(snapshot);`
pub fn applyAgentThread(model: *Model, snapshot: core.AgentThreadSnapshotView) !bool {
    const pane = model.panes.find(snapshot.pane_id) orelse return false;
    if (!try pane.applyAgentThread(snapshot)) {
        return false;
    }

    model.panes_revision +%= 1;
    return true;
}

/// Mutates the composer through its owning pane. Example: `_ = model.editAgentComposer(id, .backspace);`
pub fn editAgentComposer(model: *Model, pane_id: core.PaneId, command: model_data.PromptCommand) bool {
    const pane = model.panes.find(pane_id) orelse return false;
    if (!pane.attached or pane.kind != .agent or !pane.editComposer(command)) {
        return false;
    }

    model.panes_revision +%= 1;
    return true;
}

/// Adds an image through its attached draft owner. Example: `_ = try model.attachAgentImage(id, path);`
pub fn attachAgentImage(model: *Model, pane_id: core.PaneId, path: []const u8) !bool {
    const pane = model.panes.find(pane_id) orelse return false;
    if (!pane.attached or pane.kind != .agent) {
        return false;
    }

    try pane.attachComposerImage(path);
    model.panes_revision +%= 1;
    return true;
}

/// Example: `_ = model.removeAgentImage(id, removal);`
pub fn removeAgentImage(model: *Model, pane_id: core.PaneId, removal: AgentPane.ImageRemoval) bool {
    const pane = model.panes.find(pane_id) orelse return false;
    if (!pane.attached or pane.kind != .agent or !pane.removeComposerImage(removal)) {
        return false;
    }

    model.panes_revision +%= 1;
    return true;
}

/// Clears only the submitted draft revision; later typing stays intact.
/// Example: `_ = model.acceptAgentPrompt(pane_id, composer_revision);`
pub fn acceptAgentPrompt(model: *Model, pane_id: core.PaneId, revision: u64) bool {
    const pane = model.panes.find(pane_id) orelse return false;
    if (!pane.attached or pane.kind != .agent or !pane.acceptComposer(revision)) {
        return false;
    }

    model.panes_revision +%= 1;
    return true;
}

/// Stores disposable transcript navigation independently of provider state.
/// Example: `_ = model.scrollAgentThread(pane_id, 3);`
pub fn scrollAgentThread(model: *Model, pane_id: core.PaneId, delta: f64) bool {
    const pane = model.panes.find(pane_id) orelse return false;
    if (!pane.attached or pane.kind != .agent or !pane.scrollConversation(delta)) {
        return false;
    }

    model.panes_revision +%= 1;
    return true;
}

/// Commits one provider-backed composer selection. Example: `_ = model.changeAgentOption(id, .{ .access = .read_only });`
pub fn changeAgentOption(model: *Model, pane_id: core.PaneId, change: agent_options.Change) bool {
    const pane = model.panes.find(pane_id) orelse return false;
    if (!pane.attached or pane.kind != .agent or !pane.changeAgentOption(change)) {
        return false;
    }

    model.panes_revision +%= 1;
    return true;
}

/// Returns the version that presenters use to observe committed changes.
///
/// ```zig
/// const before = model.version();
/// ```
pub fn version(model: *const Model) VersionType {
    return .{
        .workspace = model.workspace_revision,
        .configuration = model.configuration_revision,
        .diagnostic = model.diagnostic_revision,
        .host = model.host.host_revision,
        .host_capabilities = model.host.host_capabilities_revision,
        .workspace_list = model.workspace_list_revision,
        .agents = model.agent_revision,
        .sidebar_animation = model.sidebar_animation_revision,
        .proxy_status = model.proxy_status_revision,
        .system_metrics = model.system_metrics_revision,
        .bars = model.bars_revision,
        .notifications = model.notifications_revision,
        .tabs = model.tabs_revision,
        .active_tab = model.active_tab_revision,
        .panes = model.panes_revision,
        .frame = model.frame_revision,
        .pane_metadata = model.pane_metadata_revision,
        .pane_foreground = model.pane_foreground_revision,
        .pane_progress = model.pane_progress_revision,
        .pane_graphics = model.pane_graphics_revision,
        .chrome = model.chrome_revision,
        .prompt = model.name_prompt.version(),
        .history = model.history_palette.version(),
        .suggestion = model.suggestion.version(),
        .path_completion = model.path_completion.version(),
        .copy = model.copy_revision,
        .viewport = model.viewport_revision,
    };
}

/// Retires the exact pane damage and frame identifiers included in a
/// successful host presentation without advancing semantic versions.
///
/// ```zig
/// const accepted = model.commitPresentation(commit);
/// ```
pub fn commitPresentation(model: *Model, commit: PresentationCommitType) PresentationCommitType {
    return presentation_delivery.retire(model, commit);
}

/// Returns the active configuration generation owned by this client.
///
/// ```zig
/// const generation = model.configurationGeneration();
/// ```
pub fn configurationGeneration(model: *const Model) u64 {
    return model.configuration_generation;
}

/// Returns the bounded client diagnostic currently shown in the chrome.
///
/// ```zig
/// const message = model.diagnostic() orelse return;
/// ```
pub fn diagnostic(model: *const Model) ?[]const u8 {
    if (model.client_diagnostic.len == 0) {
        return null;
    }

    return model.client_diagnostic.message();
}

/// Replaces the visible diagnostic after validating its bounded text.
///
/// ```zig
/// _ = try model.replaceDiagnostic(diagnostic);
/// ```
pub fn replaceDiagnostic(model: *Model, diagnostic_value: model_data.Diagnostic) !model_data.Change {
    if (diagnostic_value.len > diagnostic_value.buffer.len) {
        return error.InvalidClientDiagnostic;
    }

    const message = diagnostic_value.buffer[0..diagnostic_value.len];
    if (!std.unicode.utf8ValidateSlice(message)) {
        return error.InvalidClientDiagnostic;
    }

    if (message.len == 0) {
        return model.clearDiagnostic();
    }

    if (model.diagnostic()) |current| {
        if (std.mem.eql(u8, current, message)) {
            return .unchanged;
        }
    }

    model.client_diagnostic = diagnostic_value;
    model.diagnostic_revision +%= 1;
    return .changed;
}

/// Formats and commits one bounded client diagnostic.
///
/// ```zig
/// _ = try model.setDiagnostic("callback failed: {s}", .{@errorName(err)});
/// ```
pub fn setDiagnostic(model: *Model, comptime format: []const u8, args: anytype) !model_data.Change {
    var diagnostic_value: model_data.Diagnostic = .{};
    diagnostic_value.set(format, args);

    return model.replaceDiagnostic(diagnostic_value);
}

/// Clears the diagnostic only when visible text exists.
///
/// ```zig
/// _ = model.clearDiagnostic();
/// ```
pub fn clearDiagnostic(model: *Model) model_data.Change {
    if (model.client_diagnostic.len == 0) {
        return .unchanged;
    }

    model.client_diagnostic.len = 0;
    model.diagnostic_revision +%= 1;
    return .changed;
}

/// Builds the immutable value snapshot passed to one configured action.
///
/// ```zig
/// const context = model.callbackContext();
/// ```
pub fn callbackContext(model: *const Model) model_data.CallbackContext {
    const slot = model.tabs.activeSlot() orelse return .{
        .sidebar_visible = model.sidebar_visible,
        .tab_count = 0,
        .active_tab_index = 0,
        .pane_count = 0,
        .focused_pane_id = 0,
    };
    const focused = model.tabs.layout[slot].focused();

    return .{
        .sidebar_visible = model.sidebar_visible,
        .tab_count = @intCast(model.tabs.count),
        .active_tab_index = @intCast(slot),
        .pane_count = @intCast(model.panes.countIn(model.tabs.location[slot].tab_id)),
        .focused_pane_id = if (focused) |pane_id| core.raw(pane_id) else 0,
    };
}

/// Returns the single plugin execution currently owned by the client.
///
/// ```zig
/// if (model.pluginExecution() != null) {
///     return;
/// }
/// ```
pub fn pluginExecution(model: *const Model) ?PluginExecutionType {
    return model.plugins.pluginExecution();
}

/// Reserves one plugin execution against the current configuration.
///
/// ```zig
/// const execution = try model.beginPluginExecution() orelse return;
/// ```
pub fn beginPluginExecution(model: *Model) !?PluginExecutionType {
    return model.plugins.beginPluginExecution(model.configuration_generation);
}

/// Finishes only the matching plugin execution and preserves newer work.
///
/// ```zig
/// const execution = model.finishPluginExecution(id) orelse return;
/// ```
pub fn finishPluginExecution(model: *Model, id: model_data.PluginExecutionId) ?PluginExecutionType {
    return model.plugins.finishPluginExecution(id);
}

/// Returns the single clipboard capture currently owned by the client.
///
/// ```zig
/// const capture = model.clipboardCapture() orelse return;
/// ```
pub fn clipboardCapture(model: *const Model) ?model_data.ClipboardCapture {
    return model.clipboard.clipboardCapture();
}

/// Reserves one capture identity for the focused attachment target.
///
/// ```zig
/// const capture = try model.beginClipboardCapture(target) orelse return;
/// ```
pub fn beginClipboardCapture(model: *Model, target: model_data.AttachmentTarget) !?model_data.ClipboardCapture {
    return model.clipboard.beginClipboardCapture(target);
}

/// Finishes only the matching capture and preserves a newer reservation.
///
/// ```zig
/// const capture = model.finishClipboardCapture(id) orelse return;
/// ```
pub fn finishClipboardCapture(model: *Model, id: model_data.ClipboardCaptureId) ?model_data.ClipboardCapture {
    return model.clipboard.finishClipboardCapture(id);
}

/// Cancels only a capture owned by the prompt that has just been sent.
/// Its worker may still complete, but exact completion matching will
/// classify that result as obsolete and release its private buffer.
///
/// ```zig
/// _ = model.cancelClipboardCapture(target);
/// ```
pub fn cancelClipboardCapture(model: *Model, target: model_data.AttachmentTarget) bool {
    return model.clipboard.cancelClipboardCapture(target);
}

/// Returns the pane-gap preference used by current and future tabs.
///
/// ```zig
/// if (model.paneGaps()) drawGutters();
/// ```
pub fn paneGaps(model: *const Model) bool {
    return model.pane_gaps;
}

/// Returns the resolved host grid and cell geometry.
///
/// ```zig
/// const host_size = model.hostSize();
/// ```
pub fn hostSize(model: *const Model) core.TerminalSize {
    return model.host.hostSize();
}

/// Returns the host features and raw pixel measurements observed so far.
///
/// ```zig
/// const capabilities = model.hostCapabilities();
/// ```
pub fn hostCapabilities(model: *const Model) model_data.HostCapabilities {
    return model.host.hostCapabilities();
}

/// Atomically reconciles raw host capabilities and resolved geometry.
///
/// ```zig
/// const commit = try model.reconcileHost(update) orelse return;
/// ```
pub fn reconcileHost(model: *Model, update: model_data.HostUpdate) !?model_data.HostCommit {
    return model.host.reconcileHost(update);
}

/// Commits one semantic capability observation and its resolved geometry.
///
/// ```zig
/// const commit = try model.observeHostCapability(observation) orelse return;
/// ```
pub fn observeHostCapability(model: *Model, observation: model_data.HostCapabilityObservation) !?model_data.HostCommit {
    return model.host.observeHostCapability(observation);
}

/// Atomically adopts one newer configuration's semantic client settings.
///
/// ```zig
/// const commit = try model.applyConfiguration(input);
/// ```
pub fn applyConfiguration(model: *Model, input: ConfigurationInputType) !model_data.ConfigurationCommit {
    if (input.generation <= model.configuration_generation) {
        return error.StaleConfiguration;
    }

    const sidebar = model.setSidebarVisible(input.sidebar_visible);
    const pane_gaps_changed = model.pane_gaps != input.pane_gaps;
    if (pane_gaps_changed) {
        tab_layout.setPaneGaps(model, input.pane_gaps);
        model.panes_revision +%= 1;
    }

    const bars_changed = model.bars.replace(input.bars) == .changed;
    if (bars_changed) {
        model.bars_revision +%= 1;
    }

    std.debug.assert(input.window_title.len <= model.window_title_template.len);
    @memcpy(model.window_title_template[0..input.window_title.len], input.window_title);
    model.window_title_template_len = @intCast(input.window_title.len);

    model.config = input.config;
    model.configuration_generation = input.generation;
    model.configuration_revision +%= 1;

    return .{
        .generation = model.configuration_generation,
        .configuration_revision = model.configuration_revision,
        .sidebar = sidebar,
        .pane_gaps_changed = pane_gaps_changed,
        .panes_revision = model.panes_revision,
        .bars_changed = bars_changed,
        .bars_revision = model.bars_revision,
    };
}

/// Returns the configured host window title template; empty disables it.
///
/// ```zig
/// const template = model.windowTitleTemplate();
/// ```
pub fn windowTitleTemplate(model: *const Model) []const u8 {
    return model.window_title_template[0..model.window_title_template_len];
}

/// Returns the immutable configured bar presentation owned by this client.
///
/// ```zig
/// const current = model.barState();
/// ```
pub fn barState(model: *const Model) *const StateType {
    return &model.bars;
}

/// Commits one current-generation dynamic block without retaining Lua values.
///
/// ```zig
/// _ = try model.updateBar(input);
/// ```
pub fn updateBar(model: *Model, input: BarUpdateInputType) !?BarUpdateCommitType {
    if (input.generation != model.configuration_generation) {
        return error.StaleBarUpdate;
    }
    if (try model.bars.update(.{
        .generation = input.generation,
        .position = input.position,
        .content = input.content,
    }) == .unchanged) {
        return null;
    }

    model.bars_revision +%= 1;
    return .{
        .generation = input.generation,
        .position = input.position,
        .bars_revision = model.bars_revision,
    };
}

/// Returns the sidebar preference committed in client state.
///
/// ```zig
/// if (model.sidebarVisible()) showSidebar();
/// ```
pub fn sidebarVisible(model: *const Model) bool {
    return model.sidebar_visible;
}

/// Returns the preferred width retained independently of host clamping.
///
/// ```zig
/// const width = model.sidebarWidth();
/// ```
pub fn sidebarWidth(model: *const Model) u16 {
    return model.sidebar_width;
}

/// Commits an explicit sidebar preference. Repeated values preserve the
/// chrome revision and produce no projection work.
///
/// ```zig
/// const change = model.setSidebarVisible(false) orelse return;
/// ```
pub fn setSidebarVisible(model: *Model, visible: bool) ?model_data.SidebarLayout {
    return model.commitSidebarLayout(visible, model.sidebar_width);
}

/// Toggles the sidebar preference and advances only the chrome revision.
///
/// ```zig
/// const change = model.toggleSidebar();
/// ```
pub fn toggleSidebar(model: *Model) model_data.SidebarLayout {
    return model.setSidebarVisible(!model.sidebar_visible).?;
}

/// Commits an exact pointer-selected width within current host geometry.
///
/// ```zig
/// const change = model.setSidebarWidth(70) orelse return;
/// ```
pub fn setSidebarWidth(model: *Model, requested_width: u16) ?model_data.SidebarLayout {
    const width = model_data.sidebar.clampInteractive(model.host.host_size.cols, requested_width);

    return model.commitSidebarLayout(model.sidebar_visible, width);
}

/// Moves the preferred width by one keybinding step.
///
/// ```zig
/// const change = model.stepSidebarWidth(.wider) orelse return;
/// ```
pub fn stepSidebarWidth(model: *Model, direction: model_data.SidebarDirection) ?model_data.SidebarLayout {
    const width = model_data.sidebar.step(model.host.host_size.cols, model.sidebar_width, direction);

    return model.commitSidebarLayout(model.sidebar_visible, width);
}

/// Restores server-retained sidebar state without losing a preference
/// merely because the current terminal is temporarily narrow.
///
/// ```zig
/// const change = model.restoreSidebarLayout(true, 73) orelse return;
/// ```
pub fn restoreSidebarLayout(model: *Model, visible: bool, preferred_width: u16) ?model_data.SidebarLayout {
    const width = @max(model_data.sidebar.minimum_width, preferred_width);

    return model.commitSidebarLayout(visible, width);
}

fn commitSidebarLayout(model: *Model, visible: bool, width: u16) ?model_data.SidebarLayout {
    if (model.sidebar_visible == visible and model.sidebar_width == width) {
        return null;
    }

    model.sidebar_visible = visible;
    model.sidebar_width = width;
    model.chrome_revision +%= 1;

    return .{
        .visible = visible,
        .width = width,
        .chrome_revision = model.chrome_revision,
    };
}

/// Returns whether the top-bar workspace list is collapsed.
///
/// ```zig
/// if (model.workspaceListCollapsed()) showActiveWorkspaceOnly();
/// ```
pub fn workspaceListCollapsed(model: *const Model) bool {
    return model.workspace_list_collapsed;
}

/// Commits an explicit workspace-list collapse preference. Repeated
/// values preserve the chrome revision.
///
/// ```zig
/// const change = model.setWorkspaceListCollapsed(true) orelse return;
/// ```
pub fn setWorkspaceListCollapsed(model: *Model, collapsed: bool) ?WorkspaceListCollapseType {
    if (model.workspace_list_collapsed == collapsed) {
        return null;
    }

    model.workspace_list_collapsed = collapsed;
    model.chrome_revision +%= 1;

    return .{
        .collapsed = collapsed,
        .chrome_revision = model.chrome_revision,
    };
}

/// Toggles the workspace-list preference and advances only chrome.
///
/// ```zig
/// const change = model.toggleWorkspaceList();
/// ```
pub fn toggleWorkspaceList(model: *Model) WorkspaceListCollapseType {
    return model.setWorkspaceListCollapsed(!model.workspace_list_collapsed).?;
}

/// Decodes a bounded runtime list and preserves the previous replica on rejection.
/// Example: `_ = try self.applyWorkspaceList(list);`
pub fn applyWorkspaceList(self: *Model, list: core.WorkspaceListView) !workspace_list_rejection.Outcome {
    var entries: [core.max_workspace_list_entries]EntryInputType = undefined;
    var count: usize = 0;
    var iterator = list.entries();
    while (try iterator.next()) |entry| {
        entries[count] = .{
            .workspace = entry.workspace,
            .name = entry.name,
            .path = entry.path,
            .tab_count = entry.tab_count,
            .branch = entry.branch,
            .dirty = entry.dirty,
        };
        count += 1;
    }

    const commit = self.reconcileWorkspaceList(
        .{
            .revision = list.revision,
            .entries = entries[0..count],
        },
    ) catch |err| {
        const rejection = workspace_list_rejection.classifyRejection(err) orelse return err;
        return .{
            .rejected = rejection,
        };
    };

    return if (commit) |value| .{
        .applied = value,
    } else .stale;
}

/// Commits one newer runtime workspace-list replica atomically. Stale
/// revisions preserve both the stored snapshot and its model version.
///
/// ```zig
/// const commit = try model.reconcileWorkspaceList(input) orelse return;
/// ```
pub fn reconcileWorkspaceList(model: *Model, input: SnapshotInputType) !?WorkspaceListCommitType {
    if (!try model.workspace_list_snapshot.replace(input)) {
        return null;
    }

    model.workspace_list_revision +%= 1;

    return .{
        .runtime_revision = model.workspace_list_snapshot.revision,
        .count = model.workspace_list_snapshot.count,
        .workspace_list_revision = model.workspace_list_revision,
    };
}

/// Borrows the immutable workspace-list projection for one presentation.
///
/// ```zig
/// const workspaces = model.workspaceListSnapshot();
/// ```
pub fn workspaceListSnapshot(model: *const Model) *const WorkspaceListSnapshot {
    return &model.workspace_list_snapshot;
}

/// Reports whether the latest runtime list contains one workspace.
///
/// ```zig
/// if (!model.knowsWorkspace(workspace)) return;
/// ```
pub fn knowsWorkspace(model: *const Model, workspace: core.WorkspaceId) bool {
    return model.workspace_list_snapshot.indexOf(workspace) != null;
}

/// Resolves one zero-based workspace position from committed client state.
///
/// ```zig
/// const workspace = model.workspaceAtPosition(0) orelse return;
/// ```
pub fn workspaceAtPosition(model: *const Model, position: usize) ?core.WorkspaceId {
    return model.workspace_list_snapshot.workspaceAtPosition(position);
}

/// Commits one changed runtime proxy state. Repeated values produce no
/// effect or presentation work.
///
/// ```zig
/// const commit = model.reconcileProxyStatus(.{ .active = true, .scope = .exact, .system_trusted = false }) orelse return;
/// ```
pub fn reconcileProxyStatus(model: *Model, status: core.ProxyStatus) ?model_data.ProxyStatusCommit {
    if (model.proxy_tls_active == status.active and model.proxy_tls_scope == status.scope and model.proxy_system_trusted == status.system_trusted) {
        return null;
    }

    const previous = model.proxy_tls_active;
    const previous_scope = model.proxy_tls_scope;
    const previous_system_trusted = model.proxy_system_trusted;
    const proxy_status_revision_before = model.proxy_status_revision;
    model.proxy_tls_active = status.active;
    model.proxy_tls_scope = status.scope;
    model.proxy_system_trusted = status.system_trusted;
    model.proxy_status_revision +%= 1;

    return .{
        .previous = previous,
        .previous_scope = previous_scope,
        .previous_system_trusted = previous_system_trusted,
        .active = status.active,
        .scope = status.scope,
        .system_trusted = status.system_trusted,
        .proxy_status_revision_before = proxy_status_revision_before,
        .proxy_status_revision = model.proxy_status_revision,
    };
}

/// Returns whether the runtime's TLS interception service is active.
///
/// ```zig
/// if (model.proxyTlsActive()) renderProxyBadge();
/// ```
pub fn proxyTlsActive(model: *const Model) bool {
    return model.proxy_tls_active;
}

/// Returns the configured interception scope reported by the runtime.
///
/// ```zig
/// const expanded = model.proxyTlsScope() == .wildcard;
/// ```
pub fn proxyTlsScope(model: *const Model) core.ProxyScope {
    return model.proxy_tls_scope;
}

/// Returns whether Telar's authority remains in the platform trust store.
///
/// ```zig
/// if (model.proxySystemTrusted()) renderTrustBadge();
/// ```
pub fn proxySystemTrusted(model: *const Model) bool {
    return model.proxy_system_trusted;
}

/// Commits one newer host-health replica. Invalid newer values preserve
/// the last usable metrics and their local version.
///
/// ```zig
/// const commit = try model.reconcileSystemMetrics(metrics) orelse return;
/// ```
pub fn reconcileSystemMetrics(model: *Model, metrics: SystemMetricsType) !?SystemMetricsCommitType {
    if (metrics.runtime_revision == 0) {
        return error.InvalidMetricsRevision;
    }

    const current_revision = if (model.system_metrics) |current| current.runtime_revision else 0;
    if (metrics.runtime_revision <= current_revision) {
        return null;
    }
    if (metrics.cpu_percent > 100) {
        return error.InvalidMetricsValue;
    }
    if (metrics.battery_percent) |battery| {
        if (battery > 100) {
            return error.InvalidMetricsValue;
        }
    }

    model.system_metrics = metrics;
    model.system_metrics_revision +%= 1;

    return .{
        .runtime_revision = metrics.runtime_revision,
        .system_metrics_revision = model.system_metrics_revision,
    };
}

/// Returns the latest immutable host-health projection, when available.
///
/// ```zig
/// const metrics = model.systemMetrics() orelse return;
/// ```
pub fn systemMetrics(model: *const Model) ?SystemMetricsType {
    return model.system_metrics;
}

/// Publishes one bounded client notification and advances its isolated
/// version. The center owns all borrowed text before this call returns.
///
/// ```zig
/// const publication = model.publishNotification(now_ns, input);
/// ```
pub fn publishNotification(model: *Model, now_ns: u64, input: model_data.NotificationInput) model_data.NotificationPublication {
    const id = model.notification_center.push(now_ns, input);
    model.notifications_revision +%= 1;

    return .{
        .id = id,
        .notifications_revision = model.notifications_revision,
    };
}

/// Borrows the immutable notification snapshot for one presentation.
///
/// ```zig
/// const snapshot = model.notificationSnapshot();
/// ```
pub fn notificationSnapshot(model: *const Model) *const model_data.Center {
    return &model.notification_center;
}

/// Returns the next notification lifecycle deadline without changing
/// client state.
///
/// ```zig
/// const deadline = model.nextNotificationDeadline(now_ns, frame_ns);
/// ```
pub fn nextNotificationDeadline(model: *const Model, now_ns: u64, frame_interval_ns: u64) ?u64 {
    return model.notification_center.nextDeadline(now_ns, frame_interval_ns);
}

/// Advances notification lifecycles to one monotonic timestamp.
///
/// ```zig
/// const change = model.advanceNotifications(now_ns) orelse return;
/// ```
pub fn advanceNotifications(model: *Model, now_ns: u64) ?model_data.NotificationChange {
    if (!model.notification_center.advance(now_ns)) {
        return null;
    }

    model.notifications_revision +%= 1;
    return .{ .notifications_revision = model.notifications_revision };
}

/// Starts one notification's exit transition and returns its semantic
/// target. Missing and already exiting identities are stale no-ops.
///
/// ```zig
/// const activation = model.activateNotification(id, now_ns) orelse return;
/// ```
pub fn activateNotification(model: *Model, id: model_data.NotificationId, now_ns: u64) ?model_data.NotificationActivation {
    const target = model.notification_center.activate(id, now_ns) orelse return null;
    model.notifications_revision +%= 1;

    return .{
        .target = target,
        .notifications_revision = model.notifications_revision,
    };
}

/// Starts one notification's exit transition without activating it.
///
/// ```zig
/// const change = model.dismissNotification(id, now_ns) orelse return;
/// ```
pub fn dismissNotification(model: *Model, id: model_data.NotificationId, now_ns: u64) ?model_data.NotificationChange {
    if (!model.notification_center.dismiss(id, now_ns)) {
        return null;
    }

    model.notifications_revision +%= 1;
    return .{ .notifications_revision = model.notifications_revision };
}

/// Reconciles one newer runtime agent snapshot and records only status
/// transitions for identities already present in the previous revision.
///
/// ```zig
/// const commit = try model.reconcileAgentSnapshot(input) orelse return;
/// ```
pub fn reconcileAgentSnapshot(model: *Model, input: AgentsSnapshotInput) !?model_data.AgentSnapshotCommit {
    if (input.revision <= model.agent_snapshot.revision) {
        return null;
    }
    if (input.agents.len > core.max_agent_snapshot_entries) {
        return error.TooManyAgents;
    }

    var status_changes: model_data.AgentStatusChanges = .{};
    for (input.agents) |agent| {
        const previous = model.agent_snapshot.find(agent.key) orelse continue;
        if (previous.status == agent.status) {
            continue;
        }

        status_changes.append(.{
            .key = agent.key,
            .pane_index = agent.pane_index,
            .provider = agent.provider,
            .previous = previous.status,
            .current = agent.status,
        });
    }

    const agent_revision_before = model.agent_revision;
    const replaced = try model.agent_snapshot.replace(input);
    std.debug.assert(replaced);
    model.agent_revision +%= 1;

    return .{
        .runtime_revision = model.agent_snapshot.revision,
        .count = model.agent_snapshot.count,
        .status_changes = status_changes,
        .agent_revision_before = agent_revision_before,
        .agent_revision = model.agent_revision,
    };
}

/// Borrows the immutable agent projection owned by this client model.
///
/// ```zig
/// const snapshot = model.agentSnapshot();
/// ```
pub fn agentSnapshot(model: *const Model) *const SnapshotType {
    return &model.agent_snapshot;
}

/// Returns the window title the focused pane of the active tab last set,
/// or an empty slice.
///
/// ```zig
/// const title = model.focusedPaneTitle();
/// ```
pub fn focusedPaneTitle(model: *const Model) []const u8 {
    const slot = model.tabs.activeSlot() orelse return "";
    const pane = tab_layout.focusedPaneConst(model, slot) orelse return "";
    return pane.titleSlice();
}

/// Returns the executable name observed for the focused pane, or an empty slice.
///
/// ```zig
/// if (std.mem.eql(u8, model.focusedPaneForeground(), "nvim")) {
///     routeToEditor();
/// }
/// ```
pub fn focusedPaneForeground(model: *const Model) []const u8 {
    const slot = model.tabs.activeSlot() orelse return "";
    const pane = tab_layout.focusedPaneConst(model, slot) orelse return "";
    return pane.foregroundName();
}

/// Reports whether one exact pane generation is current.
///
/// ```zig
/// if (!model.knowsAgent(key)) discardNotification();
/// ```
pub fn knowsAgent(model: *const Model, key: model_data.AgentKey) bool {
    return model.agent_snapshot.find(key) != null;
}

/// Returns the focused agent that finished unseen, once per completion,
/// so the client can acknowledge it. Focus and the snapshot decide; no
/// version advances.
///
/// ```zig
/// const key = model.takeAgentAcknowledgement() orelse return;
/// ```
pub fn takeAgentAcknowledgement(model: *Model) ?model_data.AgentKey {
    const slot = model.tabs.activeSlot() orelse return null;
    const pane_id = model.tabs.layout[slot].focused() orelse return null;
    const key = model.agent_snapshot.keyForPane(model.tabs.location[slot], pane_id) orelse return null;
    const agent = model.agent_snapshot.find(key).?;
    const already = if (model.acknowledged_agent) |acknowledged| std.meta.eql(acknowledged, key) else false;

    if (agent.status != .done) {
        if (already) {
            model.acknowledged_agent = null;
        }

        return null;
    }

    if (already) {
        return null;
    }

    model.acknowledged_agent = key;
    return key;
}

/// Reports whether the latest runtime state requires sidebar animation.
///
/// ```zig
/// if (model.sidebarAnimationActive()) scheduleTick();
/// ```
pub fn sidebarAnimationActive(model: *const Model) bool {
    if (model.agent_snapshot.hasWorkingAgent()) {
        return true;
    }

    var panes = model.panes.iterateConst(null);
    while (panes.next()) |pane| {
        if (pane.progress_state == .set or pane.progress_state == .indeterminate) {
            return true;
        }
    }

    return false;
}

/// Returns the current model-owned animation frame rendered by the
/// sidebar.
///
/// ```zig
/// const frame = model.sidebarAnimationFrame();
/// ```
pub fn sidebarAnimationFrame(model: *const Model) u8 {
    return model.sidebar_animation_frame;
}

/// Advances the visible sidebar animation only while a working agent
/// exists and publishes one dedicated presenter revision.
///
/// ```zig
/// const change = model.advanceSidebarAnimation() orelse return;
/// ```
pub fn advanceSidebarAnimation(model: *Model) ?model_data.SidebarAnimationChange {
    if (!model.sidebarAnimationActive()) {
        return null;
    }

    model.sidebar_animation_frame +%= 1;
    model.sidebar_animation_revision +%= 1;

    return .{
        .frame = model.sidebar_animation_frame,
        .sidebar_animation_revision = model.sidebar_animation_revision,
    };
}

/// Resolves a sidebar identity into local focus or a runtime handoff
/// without exposing agent replica storage to the input adapter.
///
/// ```zig
/// const plan = model.planAgentNavigation(key) orelse return;
/// ```
pub fn planAgentNavigation(model: *const Model, key: model_data.AgentKey) ?model_data.AgentNavigationPlan {
    const agent = model.agent_snapshot.find(key) orelse return null;
    if (model.panes.findConst(key.pane_id)) |pane| {
        const active = model.tabs.activeSlot() orelse return null;
        const tab_id = pane.location.tab_id;

        return .{ .local = .{
            .pane_id = key.pane_id,
            .select_tab = if (model.tabs.location[active].tab_id == tab_id) null else tab_id,
        } };
    }

    return .{ .handoff = .{
        .pane_id = key.pane_id,
        .fallback_workspace = switch (agent.location.workspace) {
            .workspace => |workspace| workspace,
            .worktree => null,
        },
    } };
}

/// Resolves the focused pane to an attachment-capable agent identity.
/// Agents whose manifest declares no attachment markers have no image shelf.
///
/// ```zig
/// const key = model.focusedAttachmentAgent() orelse return;
/// ```
pub fn focusedAttachmentAgent(model: *const Model) ?model_data.AgentKey {
    const slot = model.tabs.activeSlot() orelse return null;
    const pane_id = model.tabs.layout[slot].focused() orelse return null;
    const key = model.agent_snapshot.keyForPane(model.tabs.location[slot], pane_id) orelse return null;
    const agent = model.agent_snapshot.find(key).?;
    if (agent.attachments == .none) {
        return null;
    }

    return key;
}

/// Resolves the focused attachment-capable agent to its capture target.
///
/// ```zig
/// const target = model.focusedAttachmentTarget() orelse return;
/// ```
pub fn focusedAttachmentTarget(model: *const Model) ?model_data.AttachmentTarget {
    const key = model.focusedAttachmentAgent() orelse return null;

    return .{
        .pane_id = key.pane_id,
        .pane_generation = key.pane_generation,
    };
}

/// Resolves the marker scheme only while the exact pane generation still
/// owns an attachment-capable agent.
///
/// ```zig
/// const markers = model.attachmentMarkers(target) orelse return;
/// ```
pub fn attachmentMarkers(model: *const Model, target: model_data.AttachmentTarget) ?core.AgentAttachmentMarkers {
    const agent = model.agent_snapshot.find(.{
        .pane_id = target.pane_id,
        .pane_generation = target.pane_generation,
    }) orelse return null;

    return if (agent.attachments == .none) null else agent.attachments;
}

/// Returns the pane identity and reporting mode last synchronized with the
/// child protocol.
///
/// ```zig
/// const reported = model.reportedPaneFocus() orelse return;
/// ```
pub fn reportedPaneFocus(model: *const Model) ?ReportedPaneFocusType {
    return model.reported_pane_focus;
}

/// Commits the active focused pane as the protocol-reporting target. The
/// returned transition names the ordered focus messages, if any.
///
/// ```zig
/// const transition = model.syncReportedPaneFocus() orelse return;
/// ```
pub fn syncReportedPaneFocus(model: *Model) ?PaneFocusReportTransitionType {
    const current: ?ReportedPaneFocusType = current: {
        const slot = model.tabs.activeSlot() orelse break :current null;
        const pane = tab_layout.focusedPane(model, slot) orelse break :current null;
        const pane_id = pane.id;

        break :current .{
            .pane_id = pane_id,
            .focus_events = pane.attached and pane.input_modes.focus_events,
        };
    };

    return model.commitReportedPaneFocus(current);
}

/// Clears an intentional focus owner and returns any required focus-out.
///
/// ```zig
/// const transition = model.clearReportedPaneFocus() orelse return;
/// ```
pub fn clearReportedPaneFocus(model: *Model) ?PaneFocusReportTransitionType {
    return model.commitReportedPaneFocus(null);
}

/// Forgets protocol focus after canonical state made the old owner stale.
///
/// ```zig
/// _ = model.forgetReportedPaneFocus();
/// ```
pub fn forgetReportedPaneFocus(model: *Model) bool {
    if (model.reported_pane_focus == null) {
        return false;
    }

    model.reported_pane_focus = null;
    return true;
}

/// Releases protocol focus only when its pane is being retired.
///
/// ```zig
/// _ = model.releaseReportedPaneFocus(pane_id);
/// ```
pub fn releaseReportedPaneFocus(model: *Model, pane_id: core.PaneId) bool {
    const reported = model.reported_pane_focus orelse return false;
    if (reported.pane_id != pane_id) {
        return false;
    }

    model.reported_pane_focus = null;
    return true;
}

fn commitReportedPaneFocus(model: *Model, current: ?ReportedPaneFocusType) ?PaneFocusReportTransitionType {
    const previous = model.reported_pane_focus;
    if (std.meta.eql(previous, current)) {
        return null;
    }

    var transition: PaneFocusReportTransitionType = .{
        .previous = previous,
        .current = current,
    };
    if (previous) |reported| {
        const moved = if (current) |focus|
            focus.pane_id != reported.pane_id
        else
            true;
        if (moved and reported.focus_events) {
            if (model.panes.find(reported.pane_id)) |pane| {
                if (pane.attached) {
                    transition.focus_out = reported.pane_id;
                }
            }
        }
    }

    if (current) |reported| {
        const entered = if (previous) |focus|
            focus.pane_id != reported.pane_id or !focus.focus_events
        else
            true;
        if (entered and reported.focus_events) {
            transition.focus_in = reported.pane_id;
        }
    }

    model.reported_pane_focus = current;
    return transition;
}

/// Returns the pane paste currently owned by this client.
///
/// ```zig
/// const session = model.panePasteSession() orelse return;
/// ```
pub fn panePasteSession(model: *const Model) ?model_data.PanePasteSession {
    return model.pane_paste;
}

/// Reports whether a streamed pane paste owns host input.
///
/// ```zig
/// if (model.panePasteActive()) return;
/// ```
pub fn panePasteActive(model: *const Model) bool {
    return model.pane_paste != null;
}

/// Captures the attached focused pane and its current bracketed-paste mode.
///
/// ```zig
/// const session = model.beginPanePaste() orelse return;
/// ```
pub fn beginPanePaste(model: *Model) ?model_data.PanePasteSession {
    if (model.pane_paste != null) {
        return null;
    }

    const plan = model.planPaneInput(.focused) orelse return null;
    const session: model_data.PanePasteSession = .{
        .pane_id = plan.pane_id,
        .bracketed_paste = plan.input_modes.bracketed_paste,
    };

    model.pane_paste = session;
    return session;
}

/// Finishes only the exact streamed paste that is still active.
///
/// ```zig
/// std.debug.assert(model.finishPanePaste(session));
/// ```
pub fn finishPanePaste(model: *Model, session: model_data.PanePasteSession) bool {
    const active = model.pane_paste orelse return false;
    if (!std.meta.eql(active, session)) {
        return false;
    }

    model.pane_paste = null;
    return true;
}

/// Releases a streamed paste only when its pane is being retired.
///
/// ```zig
/// _ = model.releasePanePaste(pane_id);
/// ```
pub fn releasePanePaste(model: *Model, pane_id: core.PaneId) bool {
    const session = model.pane_paste orelse return false;
    if (session.pane_id != pane_id) {
        return false;
    }

    model.pane_paste = null;
    return true;
}

/// Resolves one user-input target without exposing pane storage. Prompts
/// and copy mode own normal pane input exclusively. Physical key and paste
/// leases retain their exact pane across focus and authority changes.
///
/// ```zig
/// const plan = model.planPaneInput(.focused) orelse return;
/// ```
pub fn planPaneInput(model: *const Model, target: model_data.PaneInputTarget) ?model_data.PaneInputPlan {
    switch (target) {
        .focused, .pane => {
            if (model.name_prompt.active() or model.copyModeActive()) {
                return null;
            }
        },
        .key_lease, .pointer_lease => {},
        .paste_session => |expected| {
            const active = model.pane_paste orelse return null;
            if (!std.meta.eql(active, expected)) {
                return null;
            }
        },
    }

    const pane = switch (target) {
        .focused => focused: {
            const slot = model.tabs.activeSlot() orelse return null;
            break :focused tab_layout.focusedPaneConst(model, slot) orelse return null;
        },
        .pane => |pane_id| explicit: {
            const slot = model.tabs.activeSlot() orelse return null;
            break :explicit model.panes.findInConst(model.tabs.location[slot].tab_id, pane_id) orelse return null;
        },
        .key_lease, .pointer_lease => |pane_id| model.panes.findConst(pane_id) orelse return null,
        .paste_session => |session| model.panes.findConst(session.pane_id) orelse return null,
    };
    if (!pane.attached or pane.kind == .agent) {
        return null;
    }

    return .{
        .pane_id = pane.id,
        .input_modes = pane.input_modes,
    };
}

/// Applies one attached runtime frame and copy-mode reconciliation as one
/// client-model commit. Broken patch bases request recovery without
/// changing state. Detached or absent panes ignore frames still in flight
/// when a workspace departure removes their local model.
///
/// ```zig
/// const outcome = try model.applyPaneFrame(frame);
/// ```
pub fn applyPaneFrame(model: *Model, frame: core.FrameView) !model_data.PaneFrameOutcome {
    const pane = model.panes.find(frame.pane_id) orelse return .detached;
    if (!pane.attached) {
        return .detached;
    }
    if (frame.base_frame_id != 0 and frame.base_frame_id != pane.applied_frame_id) {
        return .{ .resync = .{
            .pane_id = frame.pane_id,
            .known_frame_id = pane.applied_frame_id,
        } };
    }

    const generation = if (pane.attachment_generation == 0) try model.allocateAttachmentGeneration() else pane.attachment_generation;
    const previous_scroll_offset = pane.scroll.offset;
    const applied = try pane.applyFrame(frame);
    pane.attach(generation);
    _ = model.reconcileCopyModeFrame(.{
        .pane_id = frame.pane_id,
        .previous_offset = previous_scroll_offset,
        .scroll = frame.scroll,
    });
    model.frame_revision +%= 1;
    const active = model.activeTabLocation();

    return .{ .applied = .{
        .pane_id = frame.pane_id,
        .location = pane.location,
        .frame_id = frame.frame_id,
        .graphics_visible = frame.scroll.atBottom(frame.rows) and
            active != null and std.meta.eql(active.?, pane.location),
        .snapshot = frame.base_frame_id == 0,
        .spans = applied.spans,
        .cells = applied.cells,
        .workspace_revision = model.workspace_revision,
        .tabs_revision = model.tabs_revision,
        .active_tab_revision = model.active_tab_revision,
        .panes_revision = model.panes_revision,
        .frame_revision = model.frame_revision,
    } };
}

/// Commits whether one pane needs a cell fallback for host graphics.
/// Unknown panes and repeated values preserve the semantic revision.
///
/// ```zig
/// const commit = model.setPaneGraphicsFallback(pane_id, true) orelse return;
/// ```
pub fn setPaneGraphicsFallback(model: *Model, pane_id: core.PaneId, visible: bool) ?model_data.PaneGraphicsFallbackCommit {
    const pane = model.panes.find(pane_id) orelse return null;
    if (pane.graphics_placeholder == visible) {
        return null;
    }

    pane.graphics_placeholder = visible;

    model.pane_graphics_revision +%= 1;

    return .{
        .pane_id = pane_id,
        .visible = visible,
        .pane_graphics_revision = model.pane_graphics_revision,
    };
}

/// Stores one runtime-owned pane metadata fact. Stale pane reports and
/// exact repeats are ignored. Cwd moves that retain the same bounded
/// display name commit storage without publishing a presentation change.
///
/// ```zig
/// const commit = try model.updatePaneMetadata(command);
/// ```
pub fn updatePaneMetadata(model: *Model, command: model_data.PaneMetadataCommand) !?PaneMetadataCommitType {
    const pane_id = switch (command) {
        .cwd => |cwd| cwd.pane_id,
        .foreground => |foreground| foreground.pane_id,
        .title => |title| title.pane_id,
    };
    const kind = std.meta.activeTag(command);
    const change: multiplexer_module.MetadataChange = if (model.panes.find(pane_id)) |pane| switch (command) {
        .cwd => |cwd| if (std.mem.eql(u8, pane.cwdSlice(), cwd.path))
            .unchanged
        else if (try pane.setCwd(cwd.path))
            .display_changed
        else
            .stored,
        .foreground => |foreground| if (pane.setForegroundName(foreground.name)) .display_changed else .unchanged,
        .title => |title| if (try pane.setTitle(title.title)) .display_changed else .unchanged,
    } else switch (command) {
        .foreground => |foreground| detached: {
            const slot = std.mem.findScalar(core.PaneId, model.tabs.foreground_pane[0..model.tabs.count], pane_id) orelse return null;
            const report: core.PaneForeground = .{
                .pane_id = foreground.pane_id,
                .name = foreground.name,
            };
            break :detached if (tab_label.applyForegroundReport(model, slot, report)) .display_changed else .unchanged;
        },
        .cwd, .title => return null,
    };
    if (change == .unchanged) {
        return null;
    }

    const display_changed = change == .display_changed;
    if (display_changed) {
        model.pane_metadata_revision +%= 1;
    }
    if (kind == .foreground) {
        std.debug.assert(display_changed);
        model.pane_foreground_revision +%= 1;
    }

    return .{
        .pane_id = pane_id,
        .kind = kind,
        .display_changed = display_changed,
        .pane_metadata_revision = model.pane_metadata_revision,
        .pane_foreground_revision = model.pane_foreground_revision,
    };
}

/// Applies one runtime-owned progress fact to its pane replica.
///
/// ```zig
/// const commit = model.updatePaneProgress(progress) orelse return;
/// ```
pub fn updatePaneProgress(model: *Model, progress: core.PaneProgress) ?model_data.PaneProgressCommit {
    const pane = model.panes.find(progress.pane_id) orelse return null;
    if (!pane.setProgress(progress)) {
        return null;
    }

    model.pane_progress_revision +%= 1;
    return .{
        .pane_id = progress.pane_id,
        .active = progress.state != .remove,
        .pane_progress_revision = model.pane_progress_revision,
    };
}

/// Commits one viewport intent for an attached pane in the active tab.
/// Copy mode owns its viewport transaction while it is active.
///
/// ```zig
/// const change = model.setPaneViewport(command) orelse return;
/// ```
pub fn setPaneViewport(model: *Model, command: model_data.PaneViewportCommand) ?model_data.PaneViewportChange {
    if (model.copyModeActive()) {
        return null;
    }

    const slot = model.tabs.activeSlot() orelse return null;
    const pane = model.panes.findIn(model.tabs.location[slot].tab_id, command.pane_id) orelse return null;
    if (!pane.attached) {
        return null;
    }

    return model_namespace.commitPaneViewport(model, pane, model_namespace.paneViewportOffset(pane, command.target));
}

/// Reports whether copy mode currently owns pane input.
///
/// ```zig
/// if (model.copyModeActive()) return;
/// ```
pub fn copyModeActive(model: *const Model) bool {
    const state = model.copy_state orelse return false;

    return state.pointer == null;
}

/// Returns the pointer gesture's stable owner without lending its state.
/// Example: `const target = model.pointerSelection() orelse return;`.
pub fn pointerSelection(model: *const Model) ?struct { pane_id: core.PaneId, dragging: bool } {
    if (model.selection_gesture) |pane_id| {
        return .{ .pane_id = pane_id, .dragging = true };
    }

    const state = model.copy_state orelse return null;
    if (state.pointer == null) {
        return null;
    }

    return .{ .pane_id = state.pane_id, .dragging = false };
}

/// Releases physical capture even when copying fails or the pane retired.
/// Example: `model.finishPointerGesture();`.
pub fn finishPointerGesture(model: *Model) void {
    model.selection_gesture = null;
}

/// Clears disposable mouse highlighting before typing or pasting.
/// Example: `_ = model.clearPointerSelection();`.
pub fn clearPointerSelection(model: *Model) bool {
    const state = model.copy_state orelse return false;
    if (state.pointer == null) {
        return false;
    }

    return model.releaseCopyMode(state.pane_id);
}

/// Starts selection only after routing has focused an attached pane.
/// Example: `_ = model.beginPointerSelection(press);`.
pub fn beginPointerSelection(model: *Model, press: PointerPressType) bool {
    if (model.copyModeActive() or model.name_prompt.active() or model.pane_paste != null) {
        return false;
    }

    const slot = model.tabs.activeSlot() orelse return false;
    const pane = tab_layout.focusedPane(model, slot) orelse return false;
    if (pane.id != press.pane_id or !pane.attached or pane.kind != .terminal or
        press.position.x >= pane.buffer.w or press.position.y >= pane.buffer.h)
    {
        return false;
    }

    if (model.selection_click_pane != pane.id) {
        model.selection_clicks = .{};
    }

    model.selection_click_pane = pane.id;
    const granularity = model.selection_clicks.press(press.position, press.now_ns);
    var state = model_data.State.init(pane.id, .{
        .x = press.position.x,
        .y = pane.scroll.offset + press.position.y,
    }, pane.scroll.offset);
    state.beginPointer(granularity, .{ .buffer = &pane.buffer, .scroll = pane.scroll });
    model.selection_gesture = pane.id;
    model.copy_state = state;
    model.copy_revision +%= 1;
    return true;
}

/// Returns the pane captured by active copy mode.
///
/// ```zig
/// const pane_id = model.copyModeTarget() orelse return;
/// ```
pub fn copyModeTarget(model: *const Model) ?core.PaneId {
    const state = model.copy_state orelse return null;

    return state.pane_id;
}

/// Returns the immutable copy-mode projection consumed by presenters.
///
/// ```zig
/// const projection = model.copyModeProjection() orelse return;
/// ```
pub fn copyModeProjection(model: *const Model) ?CopyModeProjectionType {
    const state = model.copy_state orelse return null;

    return .{ .pane_id = state.pane_id, .view = state.view() };
}

/// Enters copy mode on the attached focused pane. An active prompt or
/// paste, missing pane or repeated request leaves the copy revision intact.
///
/// ```zig
/// if (model.enterCopyMode()) observe(model.version());
/// ```
pub fn enterCopyMode(model: *Model) bool {
    if (model.copyModeActive() or model.name_prompt.active() or model.pane_paste != null) {
        return false;
    }

    const slot = model.tabs.activeSlot() orelse return false;
    const pane = tab_layout.focusedPane(model, slot) orelse return false;
    if (!pane.attached or pane.kind != .terminal) {
        return false;
    }

    const cursor: model_data.Point = if (pane.cursor.visible)
        .{ .x = pane.cursor.x, .y = pane.scroll.offset + pane.cursor.y }
    else
        .{ .x = 0, .y = pane.scroll.offset + pane.buffer.h -| 1 };
    model.copy_state = model_data.State.init(pane.id, cursor, pane.scroll.offset);
    model.copy_revision +%= 1;
    return true;
}

/// Plans one copy-mode command without mutating state or performing
/// runtime effects. Missing targets plan a local exit.
///
/// ```zig
/// const plan = model.planCopyMode(.{ .key = key }) orelse return;
/// ```
pub fn planCopyMode(model: *const Model, command: model_data.CopyModeCommand) ?CopyModePlanType {
    const previous = model.copy_state orelse return null;
    const pane = model.activePaneConst(previous.pane_id) orelse
        return model.planCopyModeExit(previous, null);
    var next = previous;

    switch (command) {
        .key => |pressed| {
            const effect = model_data.copy_mode.applyKey(&next, pressed, .{ .buffer = &pane.buffer, .scroll = pane.scroll });
            if (!effect.handled) {
                return null;
            }
            if (effect.search) |direction| {
                return .{
                    .expected_revision = model.copy_revision,
                    .previous = previous,
                    .next = next,
                    .viewport = model_namespace.copyModeViewport(pane, next.viewport_offset),
                    .search = direction,
                };
            }
            if (effect.open_link) {
                const target = cells_module.extract(&pane.buffer, pane.scroll, .{
                    .x = next.cursor.x,
                    .y = next.cursor.y,
                }) orelse return null;

                return .{
                    .expected_revision = model.copy_revision,
                    .previous = previous,
                    .next = next,
                    .open_link = target,
                };
            }
            if (effect.exit) {
                const selection: ?core.CopySelection = if (effect.copy and next.anchor != null) .{
                    .pane_id = next.pane_id,
                    .start_x = next.anchor.?.x,
                    .start_y = next.anchor.?.y,
                    .end_x = next.cursor.x,
                    .end_y = next.cursor.y,
                    .linewise = next.linewise,
                } else null;

                return model.planCopyModeExit(previous, selection);
            }
        },
        .pointer => |motion| {
            if (previous.pointer == null or model.selection_gesture != previous.pane_id) {
                return null;
            }

            next.movePointer(motion, .{ .buffer = &pane.buffer, .scroll = pane.scroll });
            if (motion.release) {
                const anchor = next.anchor orelse return model.planCopyModeExit(previous, null);

                return .{
                    .expected_revision = model.copy_revision,
                    .previous = previous,
                    .next = next,
                    .selection = .{
                        .pane_id = next.pane_id,
                        .start_x = anchor.x,
                        .start_y = anchor.y,
                        .end_x = next.cursor.x,
                        .end_y = next.cursor.y,
                        .linewise = next.linewise,
                    },
                };
            }
        },
        .cancel_pointer => {
            if (previous.pointer == null) {
                return null;
            }

            return model.planCopyModeExit(previous, null);
        },
        .vertical => |delta| next.vertical(delta, .{ .scroll = pane.scroll, .rows = pane.buffer.h }),
        .matches => |found| {
            if (found.pane_id != previous.pane_id or previous.pointer != null) {
                return null;
            }

            next.applyMatches(found.matches, .{ .scroll = pane.scroll, .rows = pane.buffer.h });
        },
        .leave => return model.planCopyModeExit(previous, null),
    }

    if (std.meta.eql(previous, next)) {
        return null;
    }

    return .{
        .expected_revision = model.copy_revision,
        .previous = previous,
        .next = next,
        .viewport = model_namespace.copyModeViewport(pane, next.viewport_offset),
    };
}

/// Commits a current copy-mode plan and returns the post-commit runtime
/// synchronization. Stale plans leave state untouched.
///
/// ```zig
/// const commit = model.commitCopyMode(plan) orelse return;
/// ```
pub fn commitCopyMode(model: *Model, plan: CopyModePlanType) ?CopyModeCommitType {
    if (model.copy_revision != plan.expected_revision) {
        return null;
    }

    const current = model.copy_state orelse return null;
    if (!std.meta.eql(current, plan.previous)) {
        return null;
    }

    if (plan.next) |next| {
        if (model.activePaneConst(next.pane_id) == null) {
            return null;
        }
    }

    var viewport_change: ?model_data.PaneViewportChange = null;
    if (plan.viewport) |viewport| {
        const slot = model.tabs.activeSlot() orelse return null;
        const pane = model.panes.findIn(model.tabs.location[slot].tab_id, viewport.pane_id) orelse return null;
        if (viewport.offset > pane.scroll.maxOffset(pane.buffer.h)) {
            return null;
        }

        viewport_change = model_namespace.commitPaneViewport(model, pane, viewport.offset);
    }

    model.copy_state = plan.next;
    model.copy_revision +%= 1;

    return .{
        .active = plan.next != null,
        .viewport = viewport_change,
        .copy_revision = model.copy_revision,
    };
}

/// Releases copy mode only when it targets the retired pane.
///
/// ```zig
/// _ = model.releaseCopyMode(pane_id);
/// ```
pub fn releaseCopyMode(model: *Model, pane_id: core.PaneId) bool {
    const state = model.copy_state orelse return false;
    if (state.pane_id != pane_id) {
        return false;
    }

    model.copy_state = null;
    model.copy_revision +%= 1;
    return true;
}

// Reconcile copy state inside the frame transaction so callers cannot
// publish screen state without the matching retained-history projection.
pub fn reconcileCopyModeFrame(model: *Model, command: CopyModeFrameType) bool {
    const state = model.copy_state orelse return false;
    if (state.pane_id != command.pane_id) {
        return false;
    }

    if (state.pointer) |pointer| {
        const pane = model.activePaneConst(state.pane_id) orelse return model.releaseCopyMode(state.pane_id);
        if (pointer.cols != pane.buffer.w or pointer.rows != pane.buffer.h) {
            return model.releaseCopyMode(state.pane_id);
        }
    }

    var next = state;
    model_data.copy_mode.onFrame(&next, command.previous_offset, command.scroll);
    if (std.meta.eql(state, next)) {
        return false;
    }

    model.copy_state = next;
    model.copy_revision +%= 1;
    return true;
}

fn planCopyModeExit(model: *const Model, previous: model_data.State, selection: ?core.CopySelection) CopyModePlanType {
    const pane = model.activePaneConst(previous.pane_id);
    const viewport = if (pane != null and previous.pointer == null)
        model_namespace.copyModeViewport(pane.?, previous.entry_offset)
    else
        null;

    return .{
        .expected_revision = model.copy_revision,
        .previous = previous,
        .next = null,
        .selection = selection,
        .viewport = viewport,
    };
}

/// Returns the active tab identity without exposing workspace storage.
///
/// ```zig
/// const location = model.activeTabLocation() orelse return;
/// ```
pub fn activeTabLocation(model: *const Model) ?core.TabLocation {
    const slot = model.tabs.activeSlot() orelse return null;
    return model.tabs.location[slot];
}

/// A pane of the active tab, or null when it belongs elsewhere.
///
/// ```zig
/// const pane = model.activePaneConst(pane_id) orelse return;
/// ```
pub fn activePaneConst(model: *const Model, pane_id: core.PaneId) ?*const AgentPane {
    const slot = model.tabs.activeSlot() orelse return null;
    return model.panes.findInConst(model.tabs.location[slot].tab_id, pane_id);
}

/// Returns the runtime workspace currently projected by this client.
///
/// ```zig
/// const workspace = model.workspaceLocation() orelse return;
/// ```
pub fn workspaceLocation(model: *const Model) ?core.WorkspaceLocation {
    return model.workspace;
}

/// The canonical name of the workspace this client shows.
///
/// ```zig
/// const name = model.workspaceName();
/// ```
pub fn workspaceName(model: *const Model) []const u8 {
    return model.workspace_name[0..model.workspace_name_len];
}

/// Resolves one tab identity inside the currently observed workspace.
///
/// ```zig
/// const location = model.tabLocation(tab_id) orelse return;
/// ```
pub fn tabLocation(model: *const Model, tab_id: core.TabId) ?core.TabLocation {
    const slot = model.tabs.find(tab_id) orelse return null;
    return model.tabs.location[slot];
}

/// Returns the attached focused pane that may authorize a new workspace
/// launch, without changing client state.
///
/// ```zig
/// const pane_id = model.planWorkspaceCreation() orelse return;
/// ```
pub fn planWorkspaceCreation(model: *const Model) ?core.PaneId {
    return (model_namespace.focusedLaunchSource(model) orelse return null).pane_id;
}

/// Captures the current workspace and attached focused pane for a tab
/// creation request without changing client state.
///
/// ```zig
/// const plan = model.planTabCreation() orelse return;
/// ```
pub fn planTabCreation(model: *const Model) ?TabCreationPlanType {
    const source = model_namespace.focusedLaunchSource(model) orelse return null;

    return .{
        .workspace = source.location.workspace,
        .cwd_source = source.pane_id,
    };
}

/// Retires the current workspace projection and captures the bounded
/// client state needed by post-commit cleanup and navigation history.
/// An already empty model is an idempotent no-op.
///
/// ```zig
/// const departure = model.departWorkspace();
/// ```
pub fn departWorkspace(model: *Model) model_data.WorkspaceDeparture {
    const departure = model_namespace.captureWorkspace(model);
    if (departure.source == null) {
        model_namespace.releaseInvalidCopyMode(model);
        return departure;
    }

    const active = model.tabs.activeSlot();
    const had_tabs = model.tabs.count != 0;
    const had_active = active != null;
    const had_visible_panes = if (active) |slot| model.panes.countIn(model.tabs.location[slot].tab_id) != 0 else false;
    model.retainWorkspaceLayouts();
    workspace_handoff.clear(model);
    model.workspace_revision +%= 1;
    if (had_tabs) {
        model.tabs_revision +%= 1;
    }
    if (had_active) {
        model.active_tab_revision +%= 1;
    }
    if (had_visible_panes) {
        model.panes_revision +%= 1;
    }
    model_namespace.releaseInvalidCopyMode(model);

    return departure;
}

/// Builds the confirmed root tab transactionally inside an empty client
/// model. Construction failure preserves the empty model and every
/// version.
///
/// ```zig
/// const activation = try model.arriveWorkspace(arrival);
/// ```
pub fn arriveWorkspace(model: *Model, arrival: model_data.WorkspaceArrival) !model_data.WorkspaceActivation {
    if (model.tabs.count != 0 or model.workspace != null) {
        return error.ModelNotEmpty;
    }

    const version_before = model.version();
    try workspace_handoff.bootstrap(
        model,
        .{
            .pane_id = arrival.pane_id,
            .location = arrival.location,
            .size = arrival.size,
        },
    );
    model.stageArrivalLayout(arrival);

    model.workspace_revision +%= 1;
    model.tabs_revision +%= 1;
    model.active_tab_revision +%= 1;
    model.panes_revision +%= 1;
    model_namespace.releaseInvalidCopyMode(model);

    return model.workspaceActivation(.{
        .pane_id = arrival.pane_id,
        .location = arrival.location,
        .version_before = version_before,
    });
}

/// Replaces the current projection with one runtime-created workspace in
/// a single semantic commit. Root construction failure preserves the
/// previous workspace and every version.
///
/// ```zig
/// const replacement = try model.replaceWorkspace(arrival);
/// ```
pub fn replaceWorkspace(model: *Model, arrival: model_data.WorkspaceArrival) !WorkspaceReplacementType {
    const departure = model_namespace.captureWorkspace(model);
    const version_before = model.version();
    if (departure.source) |source| {
        if (std.meta.eql(source, arrival.location.workspace)) {
            return error.WorkspaceAlreadyActive;
        }
    }

    const saved_before = model.saved_layouts;
    model.retainWorkspaceLayouts();
    errdefer model.saved_layouts = saved_before;
    try workspace_handoff.replaceWithRoot(model, .{
        .pane_id = arrival.pane_id,
        .location = arrival.location,
        .size = arrival.size,
    });
    model.stageArrivalLayout(arrival);

    model.workspace_revision +%= 1;
    model.tabs_revision +%= 1;
    model.active_tab_revision +%= 1;
    model.panes_revision +%= 1;
    model_namespace.releaseInvalidCopyMode(model);

    return .{
        .departure = departure,
        .activation = model.workspaceActivation(.{
            .pane_id = arrival.pane_id,
            .location = arrival.location,
            .version_before = version_before,
        }),
    };
}

fn retainWorkspaceLayouts(model: *Model) void {
    const active = model.activeTabLocation() orelse return;
    for (0..model.tabs.count) |slot| {
        // A provisional root must not replace the complete retained tree
        // while its canonical membership response is still pending.
        if (!model.tabs.snapshot_loaded[slot]) {
            continue;
        }

        const location = model.tabs.location[slot];
        const focused = model.tabs.layout[slot].focused() orelse continue;
        model.saved_layouts.retain(.{
            .location = location,
            .pane_id = focused,
            .workspace_active = std.meta.eql(active, location),
            .layout = model.tabs.layout[slot],
        });
    }
}

fn stageArrivalLayout(model: *Model, arrival: model_data.WorkspaceArrival) void {
    const saved_layout = if (model.saved_layouts.find(arrival.location)) |saved| saved.layout else arrival.saved_layout;
    if (saved_layout) |saved| {
        std.debug.assert(model.tabs.find(arrival.location.tab_id) != null);
        model.pending_layout_restore = .{
            .location = arrival.location,
            .layout = saved,
        };
    }
}

fn workspaceActivation(model: *const Model, seed: WorkspaceActivationSeedType) model_data.WorkspaceActivation {
    return .{
        .pane_id = seed.pane_id,
        .location = seed.location,
        .workspace_revision_before = seed.version_before.workspace,
        .tabs_revision_before = seed.version_before.tabs,
        .active_tab_revision_before = seed.version_before.active_tab,
        .panes_revision_before = seed.version_before.panes,
        .copy_revision_before = seed.version_before.copy,
        .copy_released = model.copy_revision != seed.version_before.copy,
        .workspace_revision = model.workspace_revision,
        .tabs_revision = model.tabs_revision,
        .active_tab_revision = model.active_tab_revision,
        .panes_revision = model.panes_revision,
        .copy_revision = model.copy_revision,
    };
}

/// Commits one canonical workspace snapshot and reports the client
/// resources that became stale. Revisions advance only for visible
/// semantic changes.
///
/// ```zig
/// const reconciliation = try model.reconcileWorkspace(snapshot);
/// ```
pub fn reconcileWorkspace(model: *Model, snapshot: WorkspaceSnapshotInput) !WorkspaceReconciliationType {
    const current_workspace = model.workspace orelse return error.UnexpectedWorkspace;
    if (!std.meta.eql(current_workspace, snapshot.workspace)) {
        return error.UnexpectedWorkspace;
    }

    if (snapshot.tabs.len == 0) {
        return error.WorkspaceHasNoTabs;
    }

    if (snapshot.tabs.len > core.max_tabs_per_workspace) {
        return error.TabLimitReached;
    }

    if (snapshot.name.len == 0 or snapshot.name.len > core.max_workspace_name_bytes) {
        return error.InvalidWorkspaceName;
    }

    const previous_active = model.activeTabLocation() orelse return error.NoActiveTab;
    var reconciliation: WorkspaceReconciliationType = .{
        .previous_active = previous_active,
        .active = previous_active,
        .workspace_changed = !std.mem.eql(u8, model.workspaceName(), snapshot.name),
        .tabs_changed = snapshot.tabs.len != model.tabs.count,
    };
    var canonical_tabs: [core.max_tabs_per_workspace]core.TabId = undefined;
    for (snapshot.tabs, 0..) |descriptor, index| {
        canonical_tabs[index] = descriptor.tab_id;
        if (index >= model.tabs.count) {
            reconciliation.tabs_changed = true;
        } else {
            if (model.tabs.location[index].tab_id != descriptor.tab_id or
                !std.mem.eql(u8, model.tabs.canonicalLabel(index), descriptor.label))
            {
                reconciliation.tabs_changed = true;
            }
        }
    }

    for (model.tabs.location[0..model.tabs.count]) |location| {
        if (std.mem.findScalar(core.TabId, canonical_tabs[0..snapshot.tabs.len], location.tab_id) != null) {
            continue;
        }

        reconciliation.removed_tabs.append(location);
        var panes = model.panes.iterateConst(location.tab_id);
        while (panes.next()) |pane| {
            reconciliation.removed_panes.append(pane.id);
        }
    }

    try workspace_reconciliation.reconcileTabs(model, snapshot);
    for (snapshot.tabs) |descriptor| {
        const slot = model.tabs.find(descriptor.tab_id).?;
        for (descriptor.foregrounds) |foreground| {
            if (model.panes.findIn(descriptor.tab_id, foreground.pane_id) != null) {
                _ = try model.updatePaneMetadata(.{ .foreground = .{ .pane_id = foreground.pane_id, .name = foreground.name } });
            }
        }

        const location = model.tabs.location[slot];
        const saved_focus = if (model.saved_layouts.find(location)) |saved| saved.pane_id else null;
        if (tab_label.applyForegroundSnapshot(model, slot, descriptor.foregrounds, saved_focus)) {
            reconciliation.tabs_changed = true;
        }
    }

    reconciliation.active = model.activeTabLocation() orelse return error.WorkspaceHasNoTabs;
    reconciliation.active_tab_changed = !std.meta.eql(previous_active, reconciliation.active);

    if (reconciliation.workspace_changed) {
        model.workspace_revision +%= 1;
    }

    if (reconciliation.tabs_changed) {
        model.tabs_revision +%= 1;
    }

    if (reconciliation.active_tab_changed) {
        model.active_tab_revision +%= 1;
    }
    model_namespace.releaseInvalidCopyMode(model);

    const active = model.tabs.activeSlot() orelse return error.WorkspaceHasNoTabs;
    reconciliation.active_snapshot_loaded = model.tabs.snapshot_loaded[active];
    reconciliation.workspace_revision = model.workspace_revision;
    reconciliation.tabs_revision = model.tabs_revision;
    reconciliation.active_tab_revision = model.active_tab_revision;
    reconciliation.panes_revision = model.panes_revision;

    return reconciliation;
}

/// Commits one canonical pane list while preserving retained pane state.
/// Only visible active-tab changes advance the pane revision.
///
/// ```zig
/// const reconciliation = try model.reconcileTab(snapshot, workbench);
/// ```
pub fn reconcileTab(model: *Model, snapshot: PaneSnapshot, area: core.Rect) !TabReconciliationType {
    const tab = model.tabs.find(snapshot.location.tab_id) orelse return error.UnexpectedTab;
    if (!std.meta.eql(model.tabs.location[tab], snapshot.location)) {
        return error.UnexpectedTab;
    }

    if (snapshot.panes.len > core.max_panes_per_tab) {
        return error.TooManyPanes;
    }

    for (snapshot.panes, 0..) |pane_id, index| {
        if (std.mem.findScalar(core.PaneId, snapshot.panes[0..index], pane_id) != null) {
            return error.DuplicatePane;
        }

        const existing = model.panes.findConst(pane_id);
        if (existing != null and !std.meta.eql(existing.?.location, snapshot.location)) {
            return error.PaneAlreadyExists;
        }
    }

    const active_location = model.activeTabLocation() orelse return error.NoActiveTab;
    const active = std.meta.eql(active_location, snapshot.location);
    const previous_layout_revision = model.tabs.layout[tab].currentRevision();
    var reconciliation: TabReconciliationType = .{
        .location = snapshot.location,
        .area = area,
        .active = active,
        .panes_changed = false,
    };
    var panes = model.panes.iterateConst(snapshot.location.tab_id);
    while (panes.next()) |pane| {
        if (std.mem.findScalar(core.PaneId, snapshot.panes, pane.id) == null) {
            reconciliation.removed_panes.append(pane.id);
        }
    }

    if (model.saved_layouts.find(snapshot.location)) |saved| {
        const already_staged = if (model.pending_layout_restore) |pending| std.meta.eql(pending.location, snapshot.location) else false;
        if (!already_staged) {
            model.pending_layout_restore = .{
                .location = snapshot.location,
                .layout = saved.layout,
                .restore_saved_focus = true,
            };
        }
    }

    const reconciled = try tab_snapshot_reconciliation.reconcile(model, snapshot, area);
    model.saved_layouts.forget(snapshot.location);
    reconciliation.panes_changed = model.tabs.layout[reconciled].currentRevision() != previous_layout_revision;
    if (reconciliation.active and reconciliation.panes_changed) {
        model.panes_revision +%= 1;
    }

    reconciliation.snapshot_loaded = model.tabs.snapshot_loaded[reconciled];
    reconciliation.layout_revision = model.tabs.layout[reconciled].currentRevision();
    reconciliation.workspace_revision = model.workspace_revision;
    reconciliation.tabs_revision = model.tabs_revision;
    reconciliation.active_tab_revision = model.active_tab_revision;
    reconciliation.panes_revision = model.panes_revision;

    return reconciliation;
}

/// Confirms a client attachment only while the requested pane is still
/// detached in the active tab. Attachment state is operational and does
/// not advance a presentation revision.
///
/// ```zig
/// const result = model.confirmPaneAttachment(attachment);
/// ```
pub fn confirmPaneAttachment(model: *Model, attachment: model_data.PaneAttachment) !model_data.StateTypesPaneAttachmentConfirmation {
    const active = model.activeTabLocation() orelse return .stale;
    if (!std.meta.eql(active, attachment.location)) {
        return .stale;
    }

    const pane = model.panes.findIn(active.tab_id, attachment.pane_id) orelse return .stale;
    if (!std.meta.eql(pane.location, attachment.location) or pane.attached) {
        return .stale;
    }

    pane.attach(try model.allocateAttachmentGeneration());
    return .confirmed;
}

fn allocateAttachmentGeneration(model: *Model) !u64 {
    if (model.next_attachment_generation == std.math.maxInt(u64)) {
        return error.AttachmentGenerationExhausted;
    }

    const generation = model.next_attachment_generation;
    model.next_attachment_generation += 1;
    return generation;
}

/// Reports whether the active client replica still needs the requested
/// attachment. Stale tabs, missing panes and confirmed panes need no repair.
///
/// ```zig
/// if (model.needsPaneAttachment(attachment)) requestSnapshot();
/// ```
pub fn needsPaneAttachment(model: *const Model, attachment: model_data.PaneAttachment) bool {
    const active = model.activeTabLocation() orelse return false;
    if (!std.meta.eql(active, attachment.location)) {
        return false;
    }

    const pane = model.panes.findInConst(active.tab_id, attachment.pane_id) orelse return false;
    return std.meta.eql(pane.location, attachment.location) and !pane.attached;
}

/// Captures one exact tab's operational attachments and whether it owns
/// the current paste or reported focus authority.
///
/// ```zig
/// const plan = try model.planTabDetachment(location);
/// ```
pub fn planTabDetachment(model: *const Model, location: core.TabLocation) !TabDetachmentPlanType {
    _ = model_namespace.findTab(model, location) orelse return error.UnexpectedTab;
    var plan: TabDetachmentPlanType = .{ .location = location };

    var panes = model.panes.iterateConst(location.tab_id);
    while (panes.next()) |pane| {
        plan.panes[plan.len] = .{
            .pane_id = pane.id,
            .attached = pane.attached,
        };
        plan.len += 1;
    }

    if (model.pane_paste) |session| {
        if (model.panes.findInConst(location.tab_id, session.pane_id) != null) {
            plan.owns_paste = true;
            plan.paste_marker_required = session.bracketed_paste;
        }
    }

    if (model.reported_pane_focus) |reported| {
        if (model.panes.findInConst(location.tab_id, reported.pane_id)) |pane| {
            plan.owns_reported_focus = true;
            plan.focus_out_required = reported.focus_events and pane.attached;
        }
    }

    return plan;
}

/// Clears only the operational attachments captured by an unchanged
/// synchronous plan. This transition advances no presentation revision.
///
/// ```zig
/// try model.commitTabDetachment(plan);
/// ```
pub fn commitTabDetachment(model: *Model, plan: TabDetachmentPlanType) !void {
    if (plan.len > core.max_panes_per_tab) {
        return error.InvalidTabDetachment;
    }

    _ = model_namespace.findTab(model, plan.location) orelse return error.StaleTabDetachment;
    const tab_id = plan.location.tab_id;
    if (model.panes.countIn(tab_id) != plan.len) {
        return error.StaleTabDetachment;
    }

    for (plan.slice(), 0..) |planned, index| {
        for (plan.slice()[0..index]) |previous| {
            if (previous.pane_id == planned.pane_id) {
                return error.InvalidTabDetachment;
            }
        }

        const pane = model.panes.findIn(tab_id, planned.pane_id) orelse return error.StaleTabDetachment;
        if (pane.attached != planned.attached) {
            return error.StaleTabDetachment;
        }
    }

    for (plan.slice()) |planned| {
        model_namespace.detachPane(model.panes.findIn(tab_id, planned.pane_id).?);
    }
}

/// Changes focus inside the active tab and reports the committed identity
/// and pane revision. Repeated, missing and directionless targets leave
/// every version intact.
///
/// ```zig
/// const focus = model.focusPane(.{ .target = .{ .direction = .left }, .area = area }) orelse return;
/// ```
pub fn focusPane(model: *Model, request: model_data.PaneFocusRequest) ?model_data.PaneFocus {
    const slot = model.tabs.activeSlot() orelse return null;
    const layout = &model.tabs.layout[slot];
    const previous = layout.focused() orelse return null;
    const focused = switch (request.target) {
        .pane_id => |pane_id| focused: {
            if (pane_id == previous or !layout.focusPane(pane_id)) {
                return null;
            }

            break :focused pane_id;
        },
        .direction => |direction| layout.focusDirection(direction, request.area) orelse return null,
    };
    std.debug.assert(focused != previous);

    model.panes_revision +%= 1;

    return .{
        .location = model.tabs.location[slot],
        .previous = previous,
        .focused = focused,
        .geometry_changed = layout.isFullscreen(),
        .panes_revision = model.panes_revision,
    };
}

/// Moves the nearest split edge around the focused pane and reports the
/// committed pane revision. Missing axes and constrained edges are no-ops.
///
/// ```zig
/// const resize = model.resizePane(.{ .direction = .right, .area = area }) orelse return;
/// ```
pub fn resizePane(model: *Model, request: model_data.ResizePaneRequest) ?model_data.PaneGeometryChange {
    const slot = model.tabs.activeSlot() orelse return null;
    const layout = &model.tabs.layout[slot];
    const focused = layout.focused() orelse return null;
    if (!layout.resizeFocused(request.direction, request.area)) {
        return null;
    }

    model.panes_revision +%= 1;

    return .{
        .location = model.tabs.location[slot],
        .focused = focused,
        .panes_revision = model.panes_revision,
        .area = request.area,
        .fullscreen = layout.isFullscreen(),
    };
}

/// Toggles fullscreen for the focused pane without discarding tiled
/// geometry. Absent or empty layouts leave every version intact.
///
/// ```zig
/// const change = model.togglePaneFullscreen(.{ .area = area }) orelse return;
/// ```
pub fn togglePaneFullscreen(model: *Model, request: model_data.TogglePaneFullscreenRequest) ?model_data.PaneGeometryChange {
    const slot = model.tabs.activeSlot() orelse return null;
    const layout = &model.tabs.layout[slot];
    const focused = layout.focused() orelse return null;
    if (!layout.toggleFullscreen()) {
        return null;
    }

    model.panes_revision +%= 1;

    return .{
        .location = model.tabs.location[slot],
        .focused = focused,
        .panes_revision = model.panes_revision,
        .area = request.area,
        .fullscreen = layout.isFullscreen(),
    };
}

/// Plans one split from active client state without changing the semantic
/// model. Both provisional sizes inherit the current cell pixel geometry.
///
/// ```zig
/// const plan = model.planPaneSplit(.{ .axis = .horizontal, .area = area }) orelse return;
/// ```
pub fn planPaneSplit(model: *Model, request: model_data.RequestPaneSplit) ?model_data.PaneSplitPlan {
    const slot = model.tabs.activeSlot() orelse return null;
    const location = model.tabs.location[slot];
    const target: *const AgentPane = (if (request.target_pane) |id| model.panes.findInConst(location.tab_id, id) else tab_layout.focusedPaneConst(model, slot)) orelse return null;
    if (!target.attached or !std.meta.eql(target.location, location)) {
        return null;
    }

    const restore_size = tab_layout.contentSize(model, slot, target.id, request.area) orelse return null;
    const prospective = tab_layout.prospectiveSplit(model, slot, .{ .pane_id = target.id, .axis = request.axis }, request.area) orelse
        return null;
    var provisional_size = multiplexer_module.rectSize(prospective.existing_content) orelse return null;
    var new_pane_size = multiplexer_module.rectSize(prospective.new_content) orelse return null;
    model_namespace.inheritCellSize(&provisional_size, restore_size);
    model_namespace.inheritCellSize(&new_pane_size, restore_size);

    return .{
        .split = .{
            .target_pane = target.id,
            .location = location,
            .axis = request.axis,
            .area = request.area,
        },
        .provisional_resize = .{ .pane_id = target.id, .size = provisional_size },
        .restore_resize = .{ .pane_id = target.id, .size = restore_size },
        .new_pane_size = new_pane_size,
        .arguments = request.arguments,
    };
}

/// Commits a runtime-created pane into the exact tab that requested it.
/// A missing target is a recoverable race; a missing tab leaves the pane
/// unrepresented so the client adapter can detach its runtime attachment.
///
/// ```zig
/// const commit = try model.commitPaneSplit(command);
/// ```
pub fn commitPaneSplit(model: *Model, command: CommitPaneSplitType) !model_data.PaneSplitCommit {
    const stale = model.finishPaneSplit(command, .{
        .disposition = .stale,
        .change = .unchanged,
        .layout_revision = 0,
    });
    const workspace = model.workspace orelse return stale;
    if (!std.meta.eql(workspace, command.split.location.workspace)) {
        return stale;
    }

    const tab = model_namespace.findTab(model, command.split.location) orelse return stale;
    const tab_id = command.split.location.tab_id;
    const active = if (model.activeTabLocation()) |current|
        std.meta.eql(current, command.split.location)
    else
        false;
    if (model.panes.find(command.new_pane)) |pane| {
        if (pane.location.tab_id != tab_id or command.new_pane == command.split.target_pane) {
            return error.PaneAlreadyExists;
        }

        if (active) {
            if (!pane.attached) {
                pane.attach(try model.allocateAttachmentGeneration());
            }
        } else {
            model_namespace.detachPane(pane);
        }

        return model.finishPaneSplit(command, .{
            .disposition = if (active) .active else .inactive,
            .change = .unchanged,
            .layout_revision = model.tabs.layout[tab].currentRevision(),
        });
    }

    if (model.panes.findIn(tab_id, command.split.target_pane) != null) {
        try pane_split.split(model, tab, .{ .existing_pane = command.split.target_pane, .new_pane = command.new_pane, .location = command.split.location, .axis = command.split.axis, .area = command.split.area });
    } else {
        try tab_snapshot_reconciliation.addDiscovered(model, tab, .{ .pane_id = command.new_pane, .location = command.split.location, .area = command.split.area });
        model.panes.find(command.new_pane).?.attach(try model.allocateAttachmentGeneration());
    }

    if (!active) {
        model_namespace.detachPane(model.panes.find(command.new_pane).?);
    } else {
        model.panes_revision +%= 1;
    }

    return model.finishPaneSplit(command, .{
        .disposition = if (active) .active else .inactive,
        .change = if (active) .changed else .unchanged,
        .layout_revision = model.tabs.layout[tab].currentRevision(),
    });
}

fn finishPaneSplit(model: *const Model, command: CommitPaneSplitType, state: PaneSplitCommitStateType) model_data.PaneSplitCommit {
    return .{
        .pane_id = command.new_pane,
        .location = command.split.location,
        .area = command.split.area,
        .disposition = state.disposition,
        .change = state.change,
        .layout_revision = state.layout_revision,
        .workspace_revision = model.workspace_revision,
        .tabs_revision = model.tabs_revision,
        .active_tab_revision = model.active_tab_revision,
        .panes_revision = model.panes_revision,
    };
}

/// Resolves failure rollback against current state rather than whichever
/// tab happens to be active when the response arrives.
///
/// ```zig
/// const recovery = model.recoverPaneSplit(.{ .split = split, .area = area });
/// ```
pub fn recoverPaneSplit(model: *Model, command: RecoverPaneSplitType) model_data.PaneSplitRecovery {
    const workspace = model.workspace orelse return .stale;
    if (!std.meta.eql(workspace, command.split.location.workspace)) {
        return .stale;
    }

    const tab = model_namespace.findTab(model, command.split.location) orelse return .stale;
    const pane = model.panes.findIn(command.split.location.tab_id, command.split.target_pane) orelse return .stale;
    if (!std.meta.eql(pane.location, command.split.location)) {
        return .stale;
    }

    const active = model.activeTabLocation() orelse return .stale;
    if (!std.meta.eql(active, command.split.location) or !pane.attached) {
        return .not_required;
    }

    const size = tab_layout.contentSize(model, tab, command.split.target_pane, command.area) orelse
        return .not_required;
    return .{ .resize = .{ .pane_id = command.split.target_pane, .size = size } };
}

/// Resolves the active attached pane that an explicit close request may
/// target without changing client state.
///
/// ```zig
/// const closure = model.planPaneClosure() orelse return;
/// ```
pub fn planPaneClosure(model: *const Model) ?model_data.PaneClosure {
    const slot = model.tabs.activeSlot() orelse return null;
    const location = model.tabs.location[slot];
    const focused = tab_layout.focusedPaneConst(model, slot) orelse return null;
    if (!focused.attached or !std.meta.eql(focused.location, location)) {
        return null;
    }

    return .{ .pane_id = focused.id, .location = location };
}

/// Applies one authoritative pane exit. Missing identities are stale
/// lifecycle traffic and leave every presentation revision unchanged.
///
/// ```zig
/// const transition = model.retirePane(pane_id);
/// ```
pub fn retirePane(model: *Model, pane_id: core.PaneId) model_data.PaneExit {
    const pane = model.panes.find(pane_id) orelse return model.stalePaneExit(pane_id);
    const tab = model.tabs.find(pane.location.tab_id) orelse return model.stalePaneExit(pane_id);
    const location = model.tabs.location[tab];
    if (!std.meta.eql(pane.location, location)) {
        return model.stalePaneExit(pane_id);
    }

    const active = if (model.activeTabLocation()) |current|
        std.meta.eql(current, location)
    else
        false;
    _ = tab_layout.removePane(model, pane_id);
    if (active) {
        model.panes_revision +%= 1;
    }

    return .{ .retired = .{
        .pane_id = pane_id,
        .location = location,
        .active = active,
        .tab_empty = model.panes.countIn(location.tab_id) == 0,
        .layout_revision = model.tabs.layout[tab].currentRevision(),
        .workspace_revision = model.workspace_revision,
        .tabs_revision = model.tabs_revision,
        .active_tab_revision = model.active_tab_revision,
        .panes_revision = model.panes_revision,
    } };
}

fn stalePaneExit(model: *const Model, pane_id: core.PaneId) model_data.PaneExit {
    return .{ .stale = .{
        .pane_id = pane_id,
        .workspace_revision = model.workspace_revision,
        .tabs_revision = model.tabs_revision,
        .active_tab_revision = model.active_tab_revision,
        .panes_revision = model.panes_revision,
    } };
}

/// Commits a runtime-confirmed tab position and advances the model once.
///
/// ```zig
/// const change = try model.applyTabPosition(location, position);
/// ```
pub fn applyTabPosition(model: *Model, location: core.TabLocation, position: u16) !model_data.Change {
    const current_workspace = model.workspace orelse return error.UnexpectedWorkspace;
    if (!std.meta.eql(current_workspace, location.workspace)) {
        return error.UnexpectedWorkspace;
    }

    const change = try tab_move.move(model, location.tab_id, position);
    if (change == .unchanged) {
        return .unchanged;
    }

    model.tabs_revision +%= 1;
    return .changed;
}

/// Commits a runtime-confirmed label and advances the tab collection once.
///
/// ```zig
/// const change = try model.renameTab(command);
/// ```
pub fn renameTab(model: *Model, command: RenameTabType) !model_data.Change {
    const current_workspace = model.workspace orelse return error.UnexpectedWorkspace;
    if (!std.meta.eql(current_workspace, command.location.workspace)) {
        return error.UnexpectedWorkspace;
    }

    const change = try tab_rename.rename(model, command.location.tab_id, command.label);
    if (change == .unchanged) {
        return .unchanged;
    }

    model.tabs_revision +%= 1;
    return .changed;
}

/// Commits a runtime-confirmed tab and makes its identity active.
///
/// ```zig
/// const creation = try model.createTab(command);
/// ```
pub fn createTab(model: *Model, command: NewTabType) !model_data.TabCreation {
    const previous = model.tabs.activeSlot() orelse return error.NoActiveTab;
    const previous_location = model.tabs.location[previous];
    const previous_layout_revision = model.tabs.layout[previous].currentRevision();
    const tabs_revision_before = model.tabs_revision;
    const active_tab_revision_before = model.active_tab_revision;
    const copy_revision_before = model.copy_revision;

    const created = try tab_creation.add(model, command.created, command.size);
    model.tabs_revision +%= 1;
    model.active_tab_revision +%= 1;
    model_namespace.releaseInvalidCopyMode(model);

    return .{
        .previous = previous_location,
        .created = command.created.location,
        .created_root_pane_id = command.created.root_pane_id,
        .created_position = command.created.position,
        .previous_layout_revision = previous_layout_revision,
        .created_layout_revision = model.tabs.layout[created].currentRevision(),
        .tabs_revision_before = tabs_revision_before,
        .active_tab_revision_before = active_tab_revision_before,
        .copy_revision_before = copy_revision_before,
        .copy_released = model.copy_revision != copy_revision_before,
        .workspace_revision = model.workspace_revision,
        .tabs_revision = model.tabs_revision,
        .active_tab_revision = model.active_tab_revision,
        .panes_revision = model.panes_revision,
        .copy_revision = model.copy_revision,
    };
}

/// Removes a runtime-confirmed tab after validating workspace closure and
/// captures missing workspace or tab identities as an exact stale commit.
///
/// ```zig
/// const commit = try model.removeTab(command);
/// ```
pub fn removeTab(model: *Model, command: RemoveTabType) !model_data.TabRemovalCommit {
    const workspace = model.workspace orelse
        return model.staleTabRemoval(command.location, .workspace);
    if (!std.meta.eql(workspace, command.location.workspace)) {
        return model.staleTabRemoval(command.location, .workspace);
    }

    const closing = model.tabs.find(command.location.tab_id) orelse
        return model.staleTabRemoval(command.location, .tab);
    if (!std.meta.eql(model.tabs.location[closing], command.location)) {
        return error.UnexpectedTab;
    }

    const workspace_removed = model.tabs.count == 1;
    if (workspace_removed != command.workspace_removed) {
        return error.UnexpectedWorkspaceRemoval;
    }

    const was_active = model.tabs.active == closing;
    const active_tab_revision_before = model.active_tab_revision;
    var panes: model_data.RemovedPanes = .{};
    var iterator = model.panes.iterateConst(command.location.tab_id);
    while (iterator.next()) |pane| {
        panes.append(pane.id);
    }

    _ = tab_removal.remove(model, command.location.tab_id);
    const active = model.activeTabLocation();
    model.tabs_revision +%= 1;
    if (was_active) {
        model.active_tab_revision +%= 1;
    }
    model_namespace.releaseInvalidCopyMode(model);

    return .{ .removed = .{
        .removed = command.location,
        .panes = panes,
        .was_active = was_active,
        .active = active,
        .workspace_removed = workspace_removed,
        .active_layout_revision = if (model.tabs.activeSlot()) |slot|
            model.tabs.layout[slot].currentRevision()
        else
            0,
        .active_tab_revision_before = active_tab_revision_before,
        .workspace_revision = model.workspace_revision,
        .tabs_revision = model.tabs_revision,
        .active_tab_revision = model.active_tab_revision,
        .panes_revision = model.panes_revision,
        .copy_revision = model.copy_revision,
    } };
}

fn staleTabRemoval(model: *const Model, location: core.TabLocation, absence: model_data.TabRemovalAbsence) model_data.TabRemovalCommit {
    return .{ .stale = .{
        .location = location,
        .absence = absence,
        .workspace_revision = model.workspace_revision,
        .tabs_revision = model.tabs_revision,
        .active_tab_revision = model.active_tab_revision,
        .panes_revision = model.panes_revision,
        .copy_revision = model.copy_revision,
    } };
}

/// Resolves one semantic target and returns the committed identity change.
///
/// ```zig
/// const selection = try model.selectTab(.{ .position = 1 }) orelse return;
/// ```
pub fn selectTab(model: *Model, target: model_data.TabSelectionTarget) !?model_data.TabSelection {
    const previous = model.tabs.activeSlot() orelse return error.NoActiveTab;
    const previous_location = model.tabs.location[previous];
    const previous_layout_revision = model.tabs.layout[previous].currentRevision();

    const changed = switch (target) {
        .tab_id => |tab_id| changed: {
            const position = model.tabs.find(tab_id) orelse return error.TabNotFound;

            break :changed tab_selection.selectPosition(model, position);
        },
        .offset => |offset| tab_selection.selectOffset(model, offset),
        .position => |position| tab_selection.selectPosition(model, position),
    };
    if (!changed) {
        return null;
    }

    const selected = model.tabs.active;
    model.active_tab_revision +%= 1;
    model_namespace.releaseInvalidCopyMode(model);

    return .{
        .previous = previous_location,
        .selected = model.tabs.location[selected],
        .previous_layout_revision = previous_layout_revision,
        .selected_layout_revision = model.tabs.layout[selected].currentRevision(),
        .workspace_revision = model.workspace_revision,
        .tabs_revision = model.tabs_revision,
        .active_tab_revision = model.active_tab_revision,
        .panes_revision = model.panes_revision,
        .copy_revision = model.copy_revision,
    };
}

/// Replaces only a matching active tab layout after validating all members. Example: `const change = try model.applyPaneLayout(request);`
pub fn applyPaneLayout(self: *Model, request: model_data.PaneLayoutRequest) !model_data.PaneFocus {
    const slot = self.tabs.activeSlot() orelse return error.NoActiveTab;
    const location = self.tabs.location[slot];
    if (!std.meta.eql(location, request.location)) {
        return error.LayoutTabMismatch;
    }

    const previous = self.tabs.layout[slot].focused() orelse return error.NoFocusedPane;
    for (request.panes.ids) |pane_id| {
        const pane = self.panes.findInConst(location.tab_id, pane_id) orelse return error.LayoutPaneMismatch;
        if (pane.kind == .agent and request.layout.surface(pane_id) != .thread) {
            return error.InvalidAgentSurface;
        }
    }

    if (!tab_layout.restoreSaved(self, slot, request.layout, request.panes)) {
        return error.LayoutPaneMismatch;
    }

    self.panes_revision +%= 1;
    return .{ .location = location, .previous = previous, .focused = request.panes.focused, .geometry_changed = true, .panes_revision = self.panes_revision };
}

/// Example: `_ = model.planAgentPrompt(pane_id);`
pub fn planAgentPrompt(self: *Model, pane_id: core.PaneId) ?AgentPromptIntent {
    const pane = self.agentPane(pane_id) orelse return null;
    const thread = pane.agent_thread orelse return null;
    if (thread.status != .ready or (std.mem.trim(u8, pane.composerSlice(), " \t\r\n").len == 0 and pane.composerImages().count == 0)) {
        return null;
    }
    const options = pane.agentOptions();
    if (!thread.accepts(options)) {
        return null;
    }

    return .{
        .pane_id = pane_id,
        .pane_generation = pane.pane_generation,
        .attachment_generation = pane.attachment_generation,
        .composer_content_revision = pane.composer_content_revision,
        .location = pane.location,
        .text = pane.composerSlice(),
        .images = pane.composerImages().view(),
        .options = options,
    };
}

/// Example: `_ = model.completeAgentPrompt(operation);`
pub fn completeAgentPrompt(self: *Model, operation: model_data.AgentOperation) bool {
    const pane = self.agentPane(operation.pane_id) orelse return false;
    if (pane.pane_generation != operation.pane_generation or pane.attachment_generation != operation.attachment_generation) {
        return false;
    }

    const revision = operation.composer_content_revision orelse return false;
    return self.acceptAgentPrompt(operation.pane_id, revision);
}
