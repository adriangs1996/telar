const sidebar = @import("../layout/sidebar.zig");
const copy_mode = @import("../input/copy_mode.zig");
const pacing = @import("pacing");
const cellgrid = @import("cellgrid");
const core = @import("telar-core");
const model_data = @import("../model.zig");
const EntryInput = @import("../workspace/EntryInput.zig");
const Pane = @import("../panes/Pane.zig");
const model_namespace = @import("model_namespace.zig");
const Tabs = @import("../workspace/Tabs.zig");
const Config = @import("Config.zig");
const Panes = @import("../panes/Panes.zig");
const LayoutSnapshot = @import("../workspace/LayoutSnapshot.zig");
const PaneBottomReservation = @import("../workspace/PaneBottomReservation.zig");
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
const PathPickerState = @import("PathPickerState.zig");
const PickListState = @import("PickListState.zig");
const SuggestionState = @import("SuggestionState.zig");
const WorkspaceListSnapshot = @import("../workspace/WorkspaceListSnapshot.zig");
const AgentSnapshot = @import("../agents/AgentSnapshot.zig");
const SystemMetrics = @import("SystemMetrics.zig");
const State = @import("../bars/State.zig");
const CpuHistory = @import("CpuHistory.zig");
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
const CommitPaneSplit = @import("CommitPaneSplit.zig");
const PaneSplitCommitState = @import("PaneSplitCommitState.zig");
const RecoverPaneSplit = @import("RecoverPaneSplit.zig");
const RenameTab = @import("RenameTab.zig");
const NewTab = @import("NewTab.zig");
const RemoveTab = @import("RemoveTab.zig");
const PeekScreen = @import("PeekScreen.zig");
const ClientModel = @This();

pub const max_window_title_template_bytes = 128;

gpa: std.mem.Allocator,
/// Settings adopted from the active configuration generation.
config: Config = .{},
/// The color and icon themes the chrome draws with. Changing either
/// advances `chrome_revision`.
theme: model_data.ColorTheme = model_data.theme_support.default_theme,
startup: model_data.StartupState = .{},
/// Whether the runtime is reachable; the chrome shows it and pane input
/// waits for it.
runtime_link: model_data.RuntimeLink = .{},
link_revision: u64 = 0,
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
/// The rows the attachment shelf asks for below one pane. Every layout
/// snapshot applies it, so the pane sizes sent to the runtime, the drawn
/// panes and pointer targeting agree on the same geometry.
pane_bottom_reservation: ?PaneBottomReservation = null,
layout_snapshot_tab: core.TabId = .invalid,
saved_layouts: SavedLayouts = .{},
clipboard: ClipboardCaptureState = .{},
plugins: PluginExecutionState = .{},
host: HostState,
to_host: model_data.HostEffects = .{},
to_runtime: model_data.Outbox = .{},
name_prompt: model_data.NamePromptState = .{},
/// The pane text an open peek shows.
peek_screen: PeekScreen = .{},
history_palette: HistoryPaletteState = .{},
suggestion: SuggestionState = .{},
path_completion: model_data.PathCompletionState = .{},
path_picker: PathPickerState = .{},
/// The list a configured pick opened in the palette.
pick_list: PickListState = .{},
workspace_revision: u64 = 0,
configuration_generation: u64 = 0,
window_title_template: [max_window_title_template_bytes]u8 = undefined,
window_title_template_len: u8 = 0,
configuration_revision: u64 = 0,
client_diagnostic: model_data.Diagnostic = .{},
diagnostic_revision: u64 = 0,
/// Every limit this client or its window reached; `limit_reached.report` writes it.
limit_reaches: core.LimitReaches = .{},
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
/// Recent CPU samples for the built-in sparkline; advances with the metrics.
cpu_history: CpuHistory = .{},
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

/// Installs runtime pane identity after a correlated attachment succeeds.
/// Example: `_ = model.identifyPane(opened);`
pub fn identifyPane(model: *ClientModel, opened: core.PaneOpened) bool {
    const pane = model.panes.find(opened.pane_id) orelse return false;
    if (!pane.attached or !std.meta.eql(pane.location, opened.location)) {
        return false;
    }

    if (model.tabs.find(pane.location.tab_id) == null) {
        return false;
    }

    if (pane.identify(opened.pane_generation)) {
        model.panes_revision +%= 1;
    }

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
        // A peek and a pick list draw inside their prompt, so the pane
        // text and the options are prompt state.
        .prompt = model.name_prompt.version() +% model.peek_screen.revision +% model.pick_list.version(),
        .history = model.history_palette.version(),
        .suggestion = model.suggestion.version(),
        .path_completion = model.path_completion.version(),
        .path_picker = model.path_picker.version(),
        .copy = model.copy_revision,
        .viewport = model.viewport_revision,
        .link = model.link_revision,
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
pub fn activePaneConst(model: *const ClientModel, pane_id: core.PaneId) ?*const Pane {
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

