const sidebar = @import("../layout/sidebar.zig");
const copy_mode = @import("../input/copy_mode.zig");
const pacing = @import("pacing");
const cellgrid = @import("cellgrid");
const agent_options = @import("../panes/agent_options.zig");
const core = @import("telar-core");
const model_data = @import("../model.zig");
const EntryInput = @import("../workspace/EntryInput.zig");
const AgentPromptIntent = @import("../agents/AgentPromptIntent.zig");
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
const SavedLayouts = @import("../workspace/SavedLayouts.zig");
const ClipboardCaptureState = @import("ClipboardCaptureState.zig");
const PluginExecutionState = @import("PluginExecutionState.zig");
const HostState = @import("HostState.zig");
const HistoryPaletteState = @import("HistoryPaletteState.zig");
const SuggestionState = @import("SuggestionState.zig");
const WorkspaceListSnapshot = @import("../workspace/WorkspaceListSnapshot.zig");
const AgentSnapshot = @import("../agents/AgentSnapshot.zig");
const SystemMetrics = @import("SystemMetrics.zig");
const State = @import("../bars/State.zig");
const ReportedPaneFocus = @import("ReportedPaneFocus.zig");
const std = @import("std");
const InitialClientState = @import("InitialClientState.zig");
const Version = @import("Version.zig");
const PresentationCommit = @import("../panes/PresentationCommit.zig");
const PluginExecution = @import("PluginExecution.zig");
const ConfigurationInput = @import("ConfigurationInput.zig");
const BarUpdateInput = @import("BarUpdateInput.zig");
const BarUpdateCommit = @import("BarUpdateCommit.zig");
const WorkspaceListCollapse = @import("WorkspaceListCollapse.zig");
const WorkspaceListInput = @import("../workspace/WorkspaceListInput.zig");
const WorkspaceListCommit = @import("WorkspaceListCommit.zig");
const SystemMetricsCommit = @import("SystemMetricsCommit.zig");
const AgentsSnapshotInput = @import("../agents/SnapshotInput.zig");
const PaneFocusReportTransition = @import("PaneFocusReportTransition.zig");
const PaneMetadataCommit = @import("PaneMetadataCommit.zig");
const PointerPress = @import("../input/PointerPress.zig");
const CopyModeProjection = @import("CopyModeProjection.zig");
const CopyModePlan = @import("CopyModePlan.zig");
const CopyModeCommit = @import("CopyModeCommit.zig");
const CopyModeFrame = @import("CopyModeFrame.zig");
const TabCreationPlan = @import("TabCreationPlan.zig");
const WorkspaceReplacement = @import("WorkspaceReplacement.zig");
const WorkspaceActivationSeed = @import("WorkspaceActivationSeed.zig");
const WorkspaceSnapshotInput = @import("../workspace/WorkspaceSnapshotInput.zig");
const WorkspaceReconciliation = @import("WorkspaceReconciliation.zig");
const PaneSnapshot = @import("../workspace/PaneSnapshot.zig");
const TabReconciliation = @import("TabReconciliation.zig");
const TabDetachmentPlan = @import("TabDetachmentPlan.zig");
const multiplexer_module = @import("../workspace/multiplexer.zig");
const CommitPaneSplit = @import("CommitPaneSplit.zig");
const PaneSplitCommitState = @import("PaneSplitCommitState.zig");
const RecoverPaneSplit = @import("RecoverPaneSplit.zig");
const RenameTab = @import("RenameTab.zig");
const NewTab = @import("NewTab.zig");
const RemoveTab = @import("RemoveTab.zig");
const ClientModel = @This();

pub const max_window_title_template_bytes = 128;

gpa: std.mem.Allocator,
/// Settings adopted from the active configuration generation.
config: Config = .{},
/// The color and icon themes the chrome draws with. Changing either
/// advances `chrome_revision`.
theme: model_data.ColorTheme = model_data.theme_support.default_theme,
icon_theme: model_data.icons.Theme = .unicode,
startup: model_data.StartupState = .{},
request_lifecycle: model_data.RequestLifecycle = .{},
/// Retained tab layouts sent to the runtime for reconnect.
client_layouts: model_data.ClientLayoutsState = .{},
navigation_history: model_data.NavigationHistory = .{},
sound_playback: model_data.SoundPlayback = .{ .configuration = .{} },
link_opening: model_data.Opening = .{},
link_pointer: model_data.Pointer = .{},
change_review: model_data.ChangeReviewSession = .{},
sidebar_animation_scheduler: pacing.DeadlineScheduler = .{},
notification_scheduler: pacing.DeadlineScheduler = .{},
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
saved_layouts: SavedLayouts = .{},
clipboard: ClipboardCaptureState = .{},
plugins: PluginExecutionState = .{},
host: HostState,
to_host: model_data.HostEffects = .{},
to_runtime: model_data.Outbox = .{},
name_prompt: model_data.NamePromptState = .{},
history_palette: HistoryPaletteState = .{},
suggestion: SuggestionState = .{},
path_completion: model_data.PathCompletionState = .{},
workspace_revision: u64 = 0,
configuration_generation: u64 = 0,
window_title_template: [max_window_title_template_bytes]u8 = undefined,
window_title_template_len: u8 = 0,
configuration_revision: u64 = 0,
client_diagnostic: model_data.Diagnostic = .{},
diagnostic_revision: u64 = 0,
workspace_list_snapshot: WorkspaceListSnapshot = .{},
workspace_list_revision: u64 = 0,
agent_snapshot: AgentSnapshot = .{},
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
system_metrics: ?SystemMetrics = null,
system_metrics_revision: u64 = 0,
bars: State = .{},
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
selection_clicks: cellgrid.ClickTracker = .{},
selection_click_pane: ?core.PaneId = null,
selection_gesture: ?core.PaneId = null,
copy_revision: u64 = 0,
reported_pane_focus: ?ReportedPaneFocus = null,
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
/// var model = ClientModel.init(gpa, true);
/// ```
pub fn init(gpa: std.mem.Allocator, pane_gaps: bool) ClientModel {
    return initWithState(gpa, .{ .pane_gaps = pane_gaps });
}

/// Creates the client model at one already active configuration generation.
///
/// ```zig
/// var model = ClientModel.initWithConfiguration(gpa, true, 1);
/// ```
pub fn initWithConfiguration(gpa: std.mem.Allocator, pane_gaps: bool, generation: u64) ClientModel {
    return initWithState(gpa, .{
        .pane_gaps = pane_gaps,
        .configuration_generation = generation,
    });
}

/// Creates the client model from its complete initial semantic state.
///
/// ```zig
/// var model = ClientModel.initWithState(gpa, initial);
/// ```
pub fn initWithState(gpa: std.mem.Allocator, initial: InitialClientState) ClientModel {
    var self: ClientModel = undefined;
    self.initInto(gpa, initial);
    return self;
}

/// Initializes the final destination without copying the reserved workspace slots.
/// Example: `model.initInto(gpa, initial);`
pub fn initInto(model: *ClientModel, gpa: std.mem.Allocator, initial: InitialClientState) void {
    initial.host_size.validate() catch unreachable;
    const cell_size = initial.host_capabilities.cellSize(
        initial.host_size.cols,
        initial.host_size.rows,
    );
    std.debug.assert(initial.host_size.cell_width_px == cell_size.width);
    std.debug.assert(initial.host_size.cell_height_px == cell_size.height);

    model.* = .{
        .gpa = gpa,
        .config = initial.config,
        .theme = initial.theme,
        .icon_theme = initial.icon_theme,
        .pane_gaps = initial.pane_gaps,
        .configuration_generation = initial.configuration_generation,
        .bars = .init(initial.bars),
        .host = .{ .host_size = initial.host_size, .host_capabilities = initial.host_capabilities },
        .sidebar_width = @max(model_data.sidebar.minimum_width, initial.sidebar_width),
    };

    std.debug.assert(initial.window_title.len <= model.window_title_template.len);
    @memcpy(model.window_title_template[0..initial.window_title.len], initial.window_title);
    model.window_title_template_len = @intCast(initial.window_title.len);
}

/// Releases all semantic workspace state owned by the model.
///
/// ```zig
/// defer model.deinit();
/// ```
pub fn deinit(model: *ClientModel) void {
    model.history_palette.deinit();
    model.clipboard.deinit(model.gpa);
    model.to_host.deinit(model.gpa);
    model.to_runtime.deinit(model.gpa);
    workspace_handoff.clear(model);
    model.saved_layouts = .{};
}

/// Installs validated reconnect layouts before the initial pane arrives.
/// Example: `model.restoreClientLayouts(layouts);`.
pub fn restoreClientLayouts(model: *ClientModel, layouts: SavedLayouts) void {
    model.saved_layouts = layouts;
}

/// Flips the focused pane between its terminal cells and its thread view and
/// reports the surface now shown. Absent or empty layouts leave every version
/// intact.
///
/// ```zig
/// const surface = model.togglePaneSurface() orelse return;
/// ```
pub fn togglePaneSurface(model: *ClientModel) ?core.PaneSurface {
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
pub fn agentPane(model: *const ClientModel, pane_id: core.PaneId) ?*const AgentPane {
    const pane = model.panes.findConst(pane_id) orelse return null;
    return if (pane.attached and pane.kind == .agent) pane else null;
}

/// Installs runtime pane identity after a correlated attachment succeeds.
/// Example: `_ = model.identifyPane(opened);`
pub fn identifyPane(model: *ClientModel, opened: core.PaneOpened) bool {
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
pub fn applyAgentThread(model: *ClientModel, snapshot: core.AgentThreadSnapshotView) !bool {
    const pane = model.panes.find(snapshot.pane_id) orelse return false;
    if (!try pane.applyAgentThread(snapshot)) {
        return false;
    }

    model.panes_revision +%= 1;
    return true;
}

/// Mutates the composer through its owning pane. Example: `_ = model.editAgentComposer(id, .backspace);`
pub fn editAgentComposer(model: *ClientModel, pane_id: core.PaneId, command: model_data.PromptCommand) bool {
    const pane = model.panes.find(pane_id) orelse return false;
    if (!pane.attached or pane.kind != .agent or !pane.editComposer(command)) {
        return false;
    }

    model.panes_revision +%= 1;
    return true;
}

/// Adds an image through its attached draft owner. Example: `_ = try model.attachAgentImage(id, path);`
pub fn attachAgentImage(model: *ClientModel, pane_id: core.PaneId, path: []const u8) !bool {
    const pane = model.panes.find(pane_id) orelse return false;
    if (!pane.attached or pane.kind != .agent) {
        return false;
    }

    try pane.attachComposerImage(path);
    model.panes_revision +%= 1;
    return true;
}

/// Example: `_ = model.removeAgentImage(id, removal);`
pub fn removeAgentImage(model: *ClientModel, pane_id: core.PaneId, removal: AgentPane.ImageRemoval) bool {
    const pane = model.panes.find(pane_id) orelse return false;
    if (!pane.attached or pane.kind != .agent or !pane.removeComposerImage(removal)) {
        return false;
    }

    model.panes_revision +%= 1;
    return true;
}

/// Clears only the submitted draft revision; later typing stays intact.
/// Example: `_ = model.acceptAgentPrompt(pane_id, composer_revision);`
pub fn acceptAgentPrompt(model: *ClientModel, pane_id: core.PaneId, revision: u64) bool {
    const pane = model.panes.find(pane_id) orelse return false;
    if (!pane.attached or pane.kind != .agent or !pane.acceptComposer(revision)) {
        return false;
    }

    model.panes_revision +%= 1;
    return true;
}

/// Stores disposable transcript navigation independently of provider state.
/// Example: `_ = model.scrollAgentThread(pane_id, 3);`
pub fn scrollAgentThread(model: *ClientModel, pane_id: core.PaneId, delta: f64) bool {
    const pane = model.panes.find(pane_id) orelse return false;
    if (!pane.attached or pane.kind != .agent or !pane.scrollConversation(delta)) {
        return false;
    }

    model.panes_revision +%= 1;
    return true;
}

/// Commits one provider-backed composer selection. Example: `_ = model.changeAgentOption(id, .{ .access = .read_only });`
pub fn changeAgentOption(model: *ClientModel, pane_id: core.PaneId, change: agent_options.Change) bool {
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
pub fn version(model: *const ClientModel) Version {
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
pub fn commitPresentation(model: *ClientModel, commit: PresentationCommit) PresentationCommit {
    return presentation_delivery.retire(model, commit);
}

/// Returns the bounded client diagnostic currently shown in the chrome.
///
/// ```zig
/// const message = model.diagnostic() orelse return;
/// ```
pub fn diagnostic(model: *const ClientModel) ?[]const u8 {
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
pub fn replaceDiagnostic(model: *ClientModel, diagnostic_value: model_data.Diagnostic) !model_data.Change {
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
pub fn setDiagnostic(model: *ClientModel, comptime format: []const u8, args: anytype) !model_data.Change {
    var diagnostic_value: model_data.Diagnostic = .{};
    diagnostic_value.set(format, args);

    return model.replaceDiagnostic(diagnostic_value);
}

/// Clears the diagnostic only when visible text exists.
///
/// ```zig
/// _ = model.clearDiagnostic();
/// ```
pub fn clearDiagnostic(model: *ClientModel) model_data.Change {
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
pub fn callbackContext(model: *const ClientModel) model_data.CallbackContext {
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

/// Reserves one plugin execution against the current configuration.
///
/// ```zig
/// const execution = try model.beginPluginExecution() orelse return;
/// ```
pub fn beginPluginExecution(model: *ClientModel) !?PluginExecution {
    return model.plugins.beginPluginExecution(model.configuration_generation);
}

/// Atomically reconciles raw host capabilities and resolved geometry.
///
/// ```zig
/// const commit = try model.reconcileHost(update) orelse return;
/// ```
pub fn reconcileHost(model: *ClientModel, update: model_data.HostUpdate) !?model_data.HostCommit {
    return model.host.reconcileHost(update);
}

/// Commits one semantic capability observation and its resolved geometry.
///
/// ```zig
/// const commit = try model.observeHostCapability(observation) orelse return;
/// ```
pub fn observeHostCapability(model: *ClientModel, observation: model_data.HostCapabilityObservation) !?model_data.HostCommit {
    return model.host.observeHostCapability(observation);
}

/// Atomically adopts one newer configuration's semantic client settings.
///
/// ```zig
/// const commit = try model.applyConfiguration(input);
/// ```
pub fn applyConfiguration(model: *ClientModel, input: ConfigurationInput) !model_data.ConfigurationCommit {
    if (input.generation <= model.configuration_generation) {
        return error.StaleConfiguration;
    }

    const sidebar_change = sidebar.setVisible(model, input.sidebar_visible);
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
        .sidebar = sidebar_change,
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
pub fn windowTitleTemplate(model: *const ClientModel) []const u8 {
    return model.window_title_template[0..model.window_title_template_len];
}

/// Commits one current-generation dynamic block without retaining Lua values.
///
/// ```zig
/// _ = try model.updateBar(input);
/// ```
pub fn updateBar(model: *ClientModel, input: BarUpdateInput) !?BarUpdateCommit {
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

/// Commits one changed runtime proxy state. Repeated values produce no
/// effect or presentation work.
///
/// ```zig
/// const commit = model.reconcileProxyStatus(.{ .active = true, .scope = .exact, .system_trusted = false }) orelse return;
/// ```
pub fn reconcileProxyStatus(model: *ClientModel, status: core.ProxyStatus) ?model_data.ProxyStatusCommit {
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

/// Commits one newer host-health replica. Invalid newer values preserve
/// the last usable metrics and their local version.
///
/// ```zig
/// const commit = try model.reconcileSystemMetrics(metrics) orelse return;
/// ```
pub fn reconcileSystemMetrics(model: *ClientModel, metrics: SystemMetrics) !?SystemMetricsCommit {
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

/// Reconciles one newer runtime agent snapshot and records only status
/// transitions for identities already present in the previous revision.
///
/// ```zig
/// const commit = try model.reconcileAgentSnapshot(input) orelse return;
/// ```
pub fn reconcileAgentSnapshot(model: *ClientModel, input: AgentsSnapshotInput) !?model_data.AgentSnapshotCommit {
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

/// Returns the window title the focused pane of the active tab last set,
/// or an empty slice.
///
/// ```zig
/// const title = model.focusedPaneTitle();
/// ```
pub fn focusedPaneTitle(model: *const ClientModel) []const u8 {
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
pub fn focusedPaneForeground(model: *const ClientModel) []const u8 {
    const slot = model.tabs.activeSlot() orelse return "";
    const pane = tab_layout.focusedPaneConst(model, slot) orelse return "";
    return pane.foregroundName();
}

/// Returns the focused agent that finished unseen, once per completion,
/// so the client can acknowledge it. Focus and the snapshot decide; no
/// version advances.
///
/// ```zig
/// const key = model.takeAgentAcknowledgement() orelse return;
/// ```
pub fn takeAgentAcknowledgement(model: *ClientModel) ?model_data.AgentKey {
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
pub fn sidebarAnimationActive(model: *const ClientModel) bool {
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

/// Advances the visible sidebar animation only while a working agent
/// exists and publishes one dedicated presenter revision.
///
/// ```zig
/// const change = model.advanceSidebarAnimation() orelse return;
/// ```
pub fn advanceSidebarAnimation(model: *ClientModel) ?model_data.SidebarAnimationChange {
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
pub fn planAgentNavigation(model: *const ClientModel, key: model_data.AgentKey) ?model_data.AgentNavigationPlan {
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
pub fn focusedAttachmentAgent(model: *const ClientModel) ?model_data.AgentKey {
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
pub fn focusedAttachmentTarget(model: *const ClientModel) ?model_data.AttachmentTarget {
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
pub fn attachmentMarkers(model: *const ClientModel, target: model_data.AttachmentTarget) ?core.AgentAttachmentMarkers {
    const agent = model.agent_snapshot.find(.{
        .pane_id = target.pane_id,
        .pane_generation = target.pane_generation,
    }) orelse return null;

    return if (agent.attachments == .none) null else agent.attachments;
}

/// Commits the active focused pane as the protocol-reporting target. The
/// returned transition names the ordered focus messages, if any.
///
/// ```zig
/// const transition = model.syncReportedPaneFocus() orelse return;
/// ```
pub fn syncReportedPaneFocus(model: *ClientModel) ?PaneFocusReportTransition {
    const current: ?ReportedPaneFocus = current: {
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
pub fn clearReportedPaneFocus(model: *ClientModel) ?PaneFocusReportTransition {
    return model.commitReportedPaneFocus(null);
}

/// Forgets protocol focus after canonical state made the old owner stale.
///
/// ```zig
/// _ = model.forgetReportedPaneFocus();
/// ```
pub fn forgetReportedPaneFocus(model: *ClientModel) bool {
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
pub fn releaseReportedPaneFocus(model: *ClientModel, pane_id: core.PaneId) bool {
    const reported = model.reported_pane_focus orelse return false;
    if (reported.pane_id != pane_id) {
        return false;
    }

    model.reported_pane_focus = null;
    return true;
}

fn commitReportedPaneFocus(model: *ClientModel, current: ?ReportedPaneFocus) ?PaneFocusReportTransition {
    const previous = model.reported_pane_focus;
    if (std.meta.eql(previous, current)) {
        return null;
    }

    var transition: PaneFocusReportTransition = .{
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

/// Reports whether a streamed pane paste owns host input.
///
/// ```zig
/// if (model.panePasteActive()) return;
/// ```
pub fn panePasteActive(model: *const ClientModel) bool {
    return model.pane_paste != null;
}

/// Captures the attached focused pane and its current bracketed-paste mode.
///
/// ```zig
/// const session = model.beginPanePaste() orelse return;
/// ```
pub fn beginPanePaste(model: *ClientModel) ?model_data.PanePasteSession {
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
pub fn finishPanePaste(model: *ClientModel, session: model_data.PanePasteSession) bool {
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
pub fn releasePanePaste(model: *ClientModel, pane_id: core.PaneId) bool {
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
pub fn planPaneInput(model: *const ClientModel, target: model_data.PaneInputTarget) ?model_data.PaneInputPlan {
    switch (target) {
        .focused, .pane => {
            if (model.name_prompt.active() or copy_mode.isActive(model)) {
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

/// Stores one runtime-owned pane metadata fact. Stale pane reports and
/// exact repeats are ignored. Cwd moves that retain the same bounded
/// display name commit storage without publishing a presentation change.
///
/// ```zig
/// const commit = try model.updatePaneMetadata(command);
/// ```
pub fn updatePaneMetadata(model: *ClientModel, command: model_data.PaneMetadataCommand) !?PaneMetadataCommit {
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
pub fn updatePaneProgress(model: *ClientModel, progress: core.PaneProgress) ?model_data.PaneProgressCommit {
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
pub fn setPaneViewport(model: *ClientModel, command: model_data.PaneViewportCommand) ?model_data.PaneViewportChange {
    if (copy_mode.isActive(model)) {
        return null;
    }

    const slot = model.tabs.activeSlot() orelse return null;
    const pane = model.panes.findIn(model.tabs.location[slot].tab_id, command.pane_id) orelse return null;
    if (!pane.attached) {
        return null;
    }

    return model_namespace.commitPaneViewport(model, pane, model_namespace.paneViewportOffset(pane, command.target));
}

// Reconcile copy state inside the frame transaction so callers cannot
// publish screen state without the matching retained-history projection.

/// Returns the active tab identity without exposing workspace storage.
///
/// ```zig
/// const location = model.activeTabLocation() orelse return;
/// ```
pub fn activeTabLocation(model: *const ClientModel) ?core.TabLocation {
    const slot = model.tabs.activeSlot() orelse return null;
    return model.tabs.location[slot];
}

/// A pane of the active tab, or null when it belongs elsewhere.
///
/// ```zig
/// const pane = model.activePaneConst(pane_id) orelse return;
/// ```
pub fn activePaneConst(model: *const ClientModel, pane_id: core.PaneId) ?*const AgentPane {
    const slot = model.tabs.activeSlot() orelse return null;
    return model.panes.findInConst(model.tabs.location[slot].tab_id, pane_id);
}

/// The canonical name of the workspace this client shows.
///
/// ```zig
/// const name = model.workspaceName();
/// ```
pub fn workspaceName(model: *const ClientModel) []const u8 {
    return model.workspace_name[0..model.workspace_name_len];
}

/// Resolves one tab identity inside the currently observed workspace.
///
/// ```zig
/// const location = model.tabLocation(tab_id) orelse return;
/// ```
pub fn tabLocation(model: *const ClientModel, tab_id: core.TabId) ?core.TabLocation {
    const slot = model.tabs.find(tab_id) orelse return null;
    return model.tabs.location[slot];
}

/// Returns the attached focused pane that may authorize a new workspace
/// launch, without changing client state.
///
/// ```zig
/// const pane_id = model.planWorkspaceCreation() orelse return;
/// ```
pub fn planWorkspaceCreation(model: *const ClientModel) ?core.PaneId {
    return (model_namespace.focusedLaunchSource(model) orelse return null).pane_id;
}

/// Captures the current workspace and attached focused pane for a tab
/// creation request without changing client state.
///
/// ```zig
/// const plan = model.planTabCreation() orelse return;
/// ```
pub fn planTabCreation(model: *const ClientModel) ?TabCreationPlan {
    const source = model_namespace.focusedLaunchSource(model) orelse return null;

    return .{
        .workspace = source.location.workspace,
        .cwd_source = source.pane_id,
    };
}

/// Confirms a client attachment only while the requested pane is still
/// detached in the active tab. Attachment state is operational and does
/// not advance a presentation revision.
///
/// ```zig
/// const result = model.confirmPaneAttachment(attachment);
/// ```
pub fn confirmPaneAttachment(model: *ClientModel, attachment: model_data.PaneAttachment) !model_data.AttachmentConfirmation {
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

pub fn allocateAttachmentGeneration(model: *ClientModel) !u64 {
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
pub fn needsPaneAttachment(model: *const ClientModel, attachment: model_data.PaneAttachment) bool {
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
pub fn planTabDetachment(model: *const ClientModel, location: core.TabLocation) !TabDetachmentPlan {
    _ = model_namespace.findTab(model, location) orelse return error.UnexpectedTab;
    var plan: TabDetachmentPlan = .{ .location = location };

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
pub fn commitTabDetachment(model: *ClientModel, plan: TabDetachmentPlan) !void {
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
pub fn focusPane(model: *ClientModel, request: model_data.PaneFocusRequest) ?model_data.PaneFocus {
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
pub fn resizePane(model: *ClientModel, request: model_data.ResizePaneRequest) ?model_data.PaneGeometryChange {
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
pub fn togglePaneFullscreen(model: *ClientModel, request: model_data.TogglePaneFullscreenRequest) ?model_data.PaneGeometryChange {
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

/// Resolves the active attached pane that an explicit close request may
/// target without changing client state.
///
/// ```zig
/// const closure = model.planPaneClosure() orelse return;
/// ```
pub fn planPaneClosure(model: *const ClientModel) ?model_data.PaneClosure {
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
pub fn retirePane(model: *ClientModel, pane_id: core.PaneId) model_data.PaneExit {
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

fn stalePaneExit(model: *const ClientModel, pane_id: core.PaneId) model_data.PaneExit {
    return .{ .stale = .{
        .pane_id = pane_id,
        .workspace_revision = model.workspace_revision,
        .tabs_revision = model.tabs_revision,
        .active_tab_revision = model.active_tab_revision,
        .panes_revision = model.panes_revision,
    } };
}

/// Replaces only a matching active tab layout after validating all members. Example: `const change = try model.applyPaneLayout(request);`
pub fn applyPaneLayout(model: *ClientModel, request: model_data.PaneLayoutRequest) !model_data.PaneFocus {
    const slot = model.tabs.activeSlot() orelse return error.NoActiveTab;
    const location = model.tabs.location[slot];
    if (!std.meta.eql(location, request.location)) {
        return error.LayoutTabMismatch;
    }

    const previous = model.tabs.layout[slot].focused() orelse return error.NoFocusedPane;
    for (request.panes.ids) |pane_id| {
        const pane = model.panes.findInConst(location.tab_id, pane_id) orelse return error.LayoutPaneMismatch;
        if (pane.kind == .agent and request.layout.surface(pane_id) != .thread) {
            return error.InvalidAgentSurface;
        }
    }

    if (!tab_layout.restoreSaved(model, slot, request.layout, request.panes)) {
        return error.LayoutPaneMismatch;
    }

    model.panes_revision +%= 1;
    return .{ .location = location, .previous = previous, .focused = request.panes.focused, .geometry_changed = true, .panes_revision = model.panes_revision };
}

/// Example: `_ = model.planAgentPrompt(pane_id);`
pub fn planAgentPrompt(model: *ClientModel, pane_id: core.PaneId) ?AgentPromptIntent {
    const pane = model.agentPane(pane_id) orelse return null;
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
pub fn completeAgentPrompt(model: *ClientModel, operation: model_data.AgentOperation) bool {
    const pane = model.agentPane(operation.pane_id) orelse return false;
    if (pane.pane_generation != operation.pane_generation or pane.attachment_generation != operation.attachment_generation) {
        return false;
    }

    const revision = operation.composer_content_revision orelse return false;
    return model.acceptAgentPrompt(operation.pane_id, revision);
}
