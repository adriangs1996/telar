//! Passive state owned by one disposable client.

const std = @import("std");
const core = @import("telar-core");
const agents = @import("../../agents/root.zig");
const attachments = @import("../../attachments/root.zig");
const bars_capability = @import("../../bars/root.zig");
const lua_config = @import("../../config/root.zig");
const graphics = @import("../../graphics/root.zig");
const input_capability = @import("../../input/root.zig");
const notifications = @import("../../notifications/root.zig");
const frontend_ui = @import("../../ui/root.zig");
const history_palette_mod = @import("history_palette.zig");
const suggestion_mod = @import("suggestion.zig");
const name_prompt = @import("name_prompt.zig");
const workspace_capability = @import("../../workspace/root.zig");

const copy_mode = input_capability.copy_mode;
const keybind = input_capability.keybind;
const kitty = graphics.kitty;
const schema = core.schema;
const layout_mod = workspace_capability.layout;
const multiplexer = workspace_capability.multiplexer;
const tabs_mod = workspace_capability.tabs;
const workspace_list_mod = workspace_capability.workspace_list;
const ui = core.ui;

const model_types = @import("types.zig");

pub const Version = model_types.Version;
pub const Change = model_types.Change;
pub const TabSelection = model_types.TabSelection;
pub const TabSelectionTarget = model_types.TabSelectionTarget;
pub const RenameTab = model_types.RenameTab;
pub const NewTab = model_types.NewTab;
pub const TabCreation = model_types.TabCreation;
pub const TabCreationPlan = model_types.TabCreationPlan;
pub const WorkspaceBookmark = model_types.WorkspaceBookmark;
pub const WorkspaceDeparture = model_types.WorkspaceDeparture;
pub const WorkspaceArrival = model_types.WorkspaceArrival;
pub const WorkspaceActivation = model_types.WorkspaceActivation;
pub const WorkspaceReplacement = model_types.WorkspaceReplacement;
const WorkspaceActivationSeed = model_types.WorkspaceActivationSeed;
pub const PaneAttachment = model_types.PaneAttachment;
pub const PaneAttachmentConfirmation = model_types.PaneAttachmentConfirmation;
pub const TabDetachmentPlan = model_types.TabDetachmentPlan;
pub const PaneFocusTarget = model_types.PaneFocusTarget;
pub const PaneFocusRequest = model_types.PaneFocusRequest;
pub const PaneFocus = model_types.PaneFocus;
pub const ReportedPaneFocus = model_types.ReportedPaneFocus;
pub const PaneFocusReportTransition = model_types.PaneFocusReportTransition;
pub const ResizePaneRequest = model_types.ResizePaneRequest;
pub const PaneGeometryChange = model_types.PaneGeometryChange;
pub const TogglePaneFullscreenRequest = model_types.TogglePaneFullscreenRequest;
pub const SidebarLayout = model_types.SidebarLayout;
pub const SidebarAnimationChange = model_types.SidebarAnimationChange;
pub const ConfigurationInput = model_types.ConfigurationInput;
pub const ConfigurationCommit = model_types.ConfigurationCommit;
pub const BarUpdateCommit = model_types.BarUpdateCommit;
pub const BarUpdateInput = model_types.BarUpdateInput;
pub const PluginExecutionId = model_types.PluginExecutionId;
pub const PluginExecution = model_types.PluginExecution;
pub const ClipboardCaptureId = model_types.ClipboardCaptureId;
pub const ClipboardCapture = model_types.ClipboardCapture;
pub const InitialClientState = model_types.InitialClientState;
pub const HostCapabilities = model_types.HostCapabilities;
pub const HostCapabilitySupport = model_types.HostCapabilitySupport;
pub const HostCapabilityObservation = model_types.HostCapabilityObservation;
pub const PixelSize = model_types.PixelSize;
pub const HostUpdate = model_types.HostUpdate;
pub const HostCapabilitiesChange = model_types.HostCapabilitiesChange;
pub const HostResizeCommit = model_types.HostResizeCommit;
pub const HostCommit = model_types.HostCommit;
pub const WorkspaceListCollapse = model_types.WorkspaceListCollapse;
pub const WorkspaceListCommit = model_types.WorkspaceListCommit;
pub const ProxyStatusCommit = model_types.ProxyStatusCommit;
pub const SystemMetrics = model_types.SystemMetrics;
pub const SystemMetricsCommit = model_types.SystemMetricsCommit;
pub const NotificationPublication = model_types.NotificationPublication;
pub const NotificationChange = model_types.NotificationChange;
pub const NotificationActivation = model_types.NotificationActivation;
pub const AgentStatusChange = model_types.AgentStatusChange;
pub const AgentStatusChanges = model_types.AgentStatusChanges;
pub const AgentSnapshotCommit = model_types.AgentSnapshotCommit;
pub const LocalAgentNavigation = model_types.LocalAgentNavigation;
pub const AgentHandoff = model_types.AgentHandoff;
pub const AgentNavigationPlan = model_types.AgentNavigationPlan;
pub const PanePasteSession = model_types.PanePasteSession;
pub const PaneInputTarget = model_types.PaneInputTarget;
pub const PaneInputPlan = model_types.PaneInputPlan;
pub const PaneFrameRecovery = model_types.PaneFrameRecovery;
pub const PaneFrameCommit = model_types.PaneFrameCommit;
pub const PaneFrameOutcome = model_types.PaneFrameOutcome;
pub const PaneGraphicsFallbackCommit = model_types.PaneGraphicsFallbackCommit;
pub const PaneMetadataKind = model_types.PaneMetadataKind;
pub const PaneMetadataCommand = model_types.PaneMetadataCommand;
pub const PaneMetadataCommit = model_types.PaneMetadataCommit;
pub const PaneViewportTarget = model_types.PaneViewportTarget;
pub const PaneViewportCommand = model_types.PaneViewportCommand;
pub const PaneViewportChange = model_types.PaneViewportChange;
pub const CopyModeCommand = model_types.CopyModeCommand;
pub const HostAppearance = model_types.HostAppearance;
pub const CopyModeProjection = model_types.CopyModeProjection;
const CopyModeFrame = model_types.CopyModeFrame;
pub const CopyModePlan = model_types.CopyModePlan;
pub const CopyModeCommit = model_types.CopyModeCommit;
pub const RequestPaneSplit = model_types.RequestPaneSplit;
pub const PaneSplit = model_types.PaneSplit;
pub const PaneResize = model_types.PaneResize;
pub const PaneSplitPlan = model_types.PaneSplitPlan;
pub const CommitPaneSplit = model_types.CommitPaneSplit;
pub const PaneSplitDisposition = model_types.PaneSplitDisposition;
pub const PaneSplitCommit = model_types.PaneSplitCommit;
const PaneSplitCommitState = model_types.PaneSplitCommitState;
pub const RecoverPaneSplit = model_types.RecoverPaneSplit;
pub const PaneSplitRecovery = model_types.PaneSplitRecovery;
pub const PaneClosure = model_types.PaneClosure;
pub const PaneRetirement = model_types.PaneRetirement;
pub const StalePaneExit = model_types.StalePaneExit;
pub const PaneExit = model_types.PaneExit;
pub const RemoveTab = model_types.RemoveTab;
pub const RemovedPanes = model_types.RemovedPanes;
pub const TabRemoval = model_types.TabRemoval;
pub const TabRemovalAbsence = model_types.TabRemovalAbsence;
pub const StaleTabRemoval = model_types.StaleTabRemoval;
pub const TabRemovalCommit = model_types.TabRemovalCommit;
pub const TabReconciliation = model_types.TabReconciliation;
pub const WorkspaceTabInput = model_types.WorkspaceTabInput;
pub const WorkspaceSnapshot = model_types.WorkspaceSnapshot;
pub const TabSnapshot = model_types.TabSnapshot;
pub const RemovedWorkspaceTabs = model_types.RemovedWorkspaceTabs;
pub const RemovedWorkspacePanes = model_types.RemovedWorkspacePanes;
pub const WorkspaceReconciliation = model_types.WorkspaceReconciliation;

pub const Model = struct {
    workspace: tabs_mod.Model,
    name_prompt: name_prompt.State = .{},
    history_palette: history_palette_mod.State = .{},
    suggestion: suggestion_mod.State = .{},
    workspace_revision: u64 = 0,
    configuration_generation: u64 = 0,
    window_title_template: [model_types.max_window_title_template_bytes]u8 = undefined,
    window_title_template_len: u8 = 0,
    configuration_revision: u64 = 0,
    client_diagnostic: lua_config.Diagnostic = .{},
    diagnostic_revision: u64 = 0,
    plugin_execution: ?PluginExecution = null,
    next_plugin_execution_id: u64 = 1,
    clipboard_capture: ?ClipboardCapture = null,
    next_clipboard_capture_id: u64 = 1,
    host_size: schema.TerminalSize,
    host_revision: u64 = 0,
    host_capabilities: HostCapabilities,
    host_capabilities_revision: u64 = 0,
    workspace_list_snapshot: workspace_list_mod.Snapshot = .{},
    workspace_list_revision: u64 = 0,
    agent_snapshot: agents.Snapshot = .{},
    agent_revision: u64 = 0,
    /// Operational state: the focused agent whose `done` status this client
    /// already acknowledged. It carries no presentation revision.
    acknowledged_agent: ?agents.AgentKey = null,
    sidebar_animation_frame: u8 = 0,
    sidebar_animation_revision: u64 = 0,
    proxy_tls_active: bool = false,
    proxy_status_revision: u64 = 0,
    system_metrics: ?SystemMetrics = null,
    system_metrics_revision: u64 = 0,
    bars: bars_capability.State = .{},
    bars_revision: u64 = 0,
    notification_center: notifications.Center = .{},
    notifications_revision: u64 = 0,
    tabs_revision: u64 = 0,
    active_tab_revision: u64 = 0,
    panes_revision: u64 = 0,
    sidebar_visible: bool = true,
    sidebar_width: u16 = frontend_ui.sidebar.default_width,
    workspace_list_collapsed: bool = false,
    chrome_revision: u64 = 0,
    copy_state: ?copy_mode.State = null,
    copy_revision: u64 = 0,
    reported_pane_focus: ?ReportedPaneFocus = null,
    pane_paste: ?PanePasteSession = null,
    frame_revision: u64 = 0,
    pane_metadata_revision: u64 = 0,
    pane_foreground_revision: u64 = 0,
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
    pub fn initWithState(gpa: std.mem.Allocator, initial: InitialClientState) Model {
        initial.host_size.validate() catch unreachable;
        const cell_size = initial.host_capabilities.cellSize(
            initial.host_size.cols,
            initial.host_size.rows,
        );
        std.debug.assert(initial.host_size.cell_width_px == cell_size.width);
        std.debug.assert(initial.host_size.cell_height_px == cell_size.height);
        var workspace = tabs_mod.Model.init(gpa);
        workspace.setPaneGaps(initial.pane_gaps);
        workspace.setCellSize(initial.host_size.cell_width_px, initial.host_size.cell_height_px);

        return .{
            .workspace = workspace,
            .configuration_generation = initial.configuration_generation,
            .bars = .init(initial.bars),
            .host_size = initial.host_size,
            .host_capabilities = initial.host_capabilities,
            .sidebar_width = @max(frontend_ui.sidebar.minimum_width, initial.sidebar_width),
        };
    }

    /// Releases all semantic workspace state owned by the model.
    ///
    /// ```zig
    /// defer model.deinit();
    /// ```
    pub fn deinit(model: *Model) void {
        model.workspace.deinit();
    }

    /// Returns the version that presenters use to observe committed changes.
    ///
    /// ```zig
    /// const before = model.version();
    /// ```
    pub fn version(model: *const Model) Version {
        return .{
            .workspace = model.workspace_revision,
            .configuration = model.configuration_revision,
            .diagnostic = model.diagnostic_revision,
            .host = model.host_revision,
            .host_capabilities = model.host_capabilities_revision,
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
            .pane_graphics = model.pane_graphics_revision,
            .chrome = model.chrome_revision,
            .prompt = model.name_prompt.version(),
            .history = model.history_palette.version(),
            .suggestion = model.suggestion.version(),
            .copy = model.copy_revision,
            .viewport = model.viewport_revision,
        };
    }

    /// Returns the active tab model, or null during bootstrap and workspace
    /// handoff when the client intentionally has no presentable tab.
    ///
    /// ```zig
    /// const active = model.activeTabModel() orelse return;
    /// ```
    pub fn activeTabModel(model: *Model) ?*multiplexer.Model {
        const active = model.workspace.active() orelse return null;

        return &active.model;
    }

    /// Borrows the active tab model for one immutable presentation projection.
    ///
    /// ```zig
    /// const active = model.activeTabModelConst() orelse return;
    /// ```
    pub fn activeTabModelConst(model: *const Model) ?*const multiplexer.Model {
        const active = model.workspace.activeConst() orelse return null;

        return &active.model;
    }

    /// Retires the exact pane damage and frame identifiers included in a
    /// successful host presentation without advancing semantic versions.
    ///
    /// ```zig
    /// model.commitPresentation(commit);
    /// ```
    pub fn commitPresentation(model: *Model, commit: multiplexer.PresentationCommit) void {
        const location = commit.location orelse return;
        const tab = model.workspace.find(location.tab_id) orelse return;
        if (!std.meta.eql(tab.location, location)) {
            return;
        }

        tab.model.commitPresentation(commit);
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
    pub fn replaceDiagnostic(model: *Model, diagnostic_value: lua_config.Diagnostic) !Change {
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
    pub fn setDiagnostic(model: *Model, comptime format: []const u8, args: anytype) !Change {
        var diagnostic_value: lua_config.Diagnostic = .{};
        diagnostic_value.set(format, args);

        return model.replaceDiagnostic(diagnostic_value);
    }

    /// Clears the diagnostic only when visible text exists.
    ///
    /// ```zig
    /// _ = model.clearDiagnostic();
    /// ```
    pub fn clearDiagnostic(model: *Model) Change {
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
    pub fn callbackContext(model: *const Model) lua_config.CallbackContext {
        const active = model.workspace.activeConst() orelse return .{
            .sidebar_visible = model.sidebar_visible,
            .tab_count = 0,
            .active_tab_index = 0,
            .pane_count = 0,
            .focused_pane_id = 0,
        };
        const focused = active.model.layout.focused();

        return .{
            .sidebar_visible = model.sidebar_visible,
            .tab_count = @intCast(model.workspace.count),
            .active_tab_index = @intCast(model.workspace.activeIndex() orelse 0),
            .pane_count = @intCast(active.model.pane_count),
            .focused_pane_id = if (focused) |pane_id| schema.id.raw(pane_id) else 0,
        };
    }

    /// Returns the single plugin execution currently owned by the client.
    ///
    /// ```zig
    /// if (model.pluginExecution() != null) {
    ///     return;
    /// }
    /// ```
    pub fn pluginExecution(model: *const Model) ?PluginExecution {
        return model.plugin_execution;
    }

    /// Reserves one plugin execution against the current configuration.
    ///
    /// ```zig
    /// const execution = try model.beginPluginExecution() orelse return;
    /// ```
    pub fn beginPluginExecution(model: *Model) !?PluginExecution {
        if (model.plugin_execution != null) {
            return null;
        }
        if (model.next_plugin_execution_id == 0) {
            return error.PluginExecutionIdExhausted;
        }

        const execution: PluginExecution = .{
            .id = @enumFromInt(model.next_plugin_execution_id),
            .configuration_generation = model.configuration_generation,
        };
        model.next_plugin_execution_id +%= 1;
        model.plugin_execution = execution;

        return execution;
    }

    /// Finishes only the matching plugin execution and preserves newer work.
    ///
    /// ```zig
    /// const execution = model.finishPluginExecution(id) orelse return;
    /// ```
    pub fn finishPluginExecution(model: *Model, id: PluginExecutionId) ?PluginExecution {
        const execution = model.plugin_execution orelse return null;
        if (execution.id != id) {
            return null;
        }

        model.plugin_execution = null;
        return execution;
    }

    /// Returns the single clipboard capture currently owned by the client.
    ///
    /// ```zig
    /// const capture = model.clipboardCapture() orelse return;
    /// ```
    pub fn clipboardCapture(model: *const Model) ?ClipboardCapture {
        return model.clipboard_capture;
    }

    /// Reserves one capture identity for the focused attachment target.
    ///
    /// ```zig
    /// const capture = try model.beginClipboardCapture(target) orelse return;
    /// ```
    pub fn beginClipboardCapture(model: *Model, target: attachments.Target) !?ClipboardCapture {
        if (model.clipboard_capture != null) {
            return null;
        }
        if (model.next_clipboard_capture_id == 0) {
            return error.ClipboardCaptureIdExhausted;
        }

        try target.validate();
        const capture: ClipboardCapture = .{
            .id = @enumFromInt(model.next_clipboard_capture_id),
            .target = target,
        };
        model.next_clipboard_capture_id +%= 1;
        model.clipboard_capture = capture;

        return capture;
    }

    /// Finishes only the matching capture and preserves a newer reservation.
    ///
    /// ```zig
    /// const capture = model.finishClipboardCapture(id) orelse return;
    /// ```
    pub fn finishClipboardCapture(model: *Model, id: ClipboardCaptureId) ?ClipboardCapture {
        const capture = model.clipboard_capture orelse return null;
        if (capture.id != id) {
            return null;
        }

        model.clipboard_capture = null;
        return capture;
    }

    /// Cancels only a capture owned by the prompt that has just been sent.
    /// Its worker may still complete, but exact completion matching will
    /// classify that result as obsolete and release its private buffer.
    ///
    /// ```zig
    /// _ = model.cancelClipboardCapture(target);
    /// ```
    pub fn cancelClipboardCapture(model: *Model, target: attachments.Target) bool {
        const capture = model.clipboard_capture orelse return false;
        if (!std.meta.eql(capture.target, target)) {
            return false;
        }

        model.clipboard_capture = null;
        return true;
    }

    /// Returns the pane-gap preference used by current and future tabs.
    ///
    /// ```zig
    /// if (model.paneGaps()) drawGutters();
    /// ```
    pub fn paneGaps(model: *const Model) bool {
        return model.workspace.pane_gaps;
    }

    /// Returns the resolved host grid and cell geometry.
    ///
    /// ```zig
    /// const host_size = model.hostSize();
    /// ```
    pub fn hostSize(model: *const Model) schema.TerminalSize {
        return model.host_size;
    }

    /// Returns the host features and raw pixel measurements observed so far.
    ///
    /// ```zig
    /// const capabilities = model.hostCapabilities();
    /// ```
    pub fn hostCapabilities(model: *const Model) HostCapabilities {
        return model.host_capabilities;
    }

    /// Atomically reconciles raw host capabilities and resolved geometry.
    ///
    /// ```zig
    /// const commit = try model.reconcileHost(update) orelse return;
    /// ```
    pub fn reconcileHost(model: *Model, update: HostUpdate) !?HostCommit {
        try update.size.validate();
        const cell_size = update.capabilities.cellSize(update.size.cols, update.size.rows);
        if (update.size.cell_width_px != cell_size.width or
            update.size.cell_height_px != cell_size.height)
        {
            return error.InconsistentHostGeometry;
        }

        const capabilities_changed = !std.meta.eql(model.host_capabilities, update.capabilities);
        const size_changed = !std.meta.eql(model.host_size, update.size);
        if (!capabilities_changed and !size_changed) {
            return null;
        }

        const capabilities = if (capabilities_changed) changed: {
            const previous = model.host_capabilities;
            model.host_capabilities = update.capabilities;
            model.host_capabilities_revision +%= 1;

            break :changed HostCapabilitiesChange{
                .previous = previous,
                .current = update.capabilities,
                .host_capabilities_revision = model.host_capabilities_revision,
            };
        } else null;
        const resize = if (size_changed) model.commitHostResize(update.size) else null;

        return .{
            .capabilities = capabilities,
            .resize = resize,
        };
    }

    /// Commits one semantic capability observation and its resolved geometry.
    ///
    /// ```zig
    /// const commit = try model.observeHostCapability(observation) orelse return;
    /// ```
    pub fn observeHostCapability(model: *Model, observation: HostCapabilityObservation) !?HostCommit {
        const capabilities = model.host_capabilities.withObservation(observation);
        if (std.meta.eql(model.host_capabilities, capabilities)) {
            return null;
        }

        return model.reconcileHost(.{
            .capabilities = capabilities,
            .size = model.resolveHostSize(capabilities),
        });
    }

    /// Settles every unanswered support probe as unsupported.
    ///
    /// ```zig
    /// const commit = try model.expireHostCapabilities() orelse return;
    /// ```
    pub fn expireHostCapabilities(model: *Model) !?HostCommit {
        const capabilities = model.host_capabilities.withExpiredProbes();
        if (std.meta.eql(model.host_capabilities, capabilities)) {
            return null;
        }

        return model.reconcileHost(.{
            .capabilities = capabilities,
            .size = model.resolveHostSize(capabilities),
        });
    }

    fn resolveHostSize(model: *const Model, capabilities: HostCapabilities) schema.TerminalSize {
        const cell_size = capabilities.cellSize(model.host_size.cols, model.host_size.rows);

        return .{
            .cols = model.host_size.cols,
            .rows = model.host_size.rows,
            .cell_width_px = cell_size.width,
            .cell_height_px = cell_size.height,
        };
    }

    fn commitHostResize(model: *Model, size: schema.TerminalSize) HostResizeCommit {
        const previous = model.host_size;
        model.workspace.setCellSize(size.cell_width_px, size.cell_height_px);
        model.host_size = size;
        model.host_revision +%= 1;

        return .{
            .previous = previous,
            .current = size,
            .grid_changed = previous.cols != size.cols or previous.rows != size.rows,
            .cell_size_changed = previous.cell_width_px != size.cell_width_px or
                previous.cell_height_px != size.cell_height_px,
            .host_revision = model.host_revision,
        };
    }

    /// Atomically adopts one newer configuration's semantic client settings.
    ///
    /// ```zig
    /// const commit = try model.applyConfiguration(input);
    /// ```
    pub fn applyConfiguration(model: *Model, input: ConfigurationInput) !ConfigurationCommit {
        if (input.generation <= model.configuration_generation) {
            return error.StaleConfiguration;
        }

        const sidebar = model.setSidebarVisible(input.sidebar_visible);
        const pane_gaps_changed = model.workspace.pane_gaps != input.pane_gaps;
        if (pane_gaps_changed) {
            model.workspace.setPaneGaps(input.pane_gaps);
            model.panes_revision +%= 1;
        }

        const bars_changed = model.bars.replace(input.bars) == .changed;
        if (bars_changed) {
            model.bars_revision +%= 1;
        }

        std.debug.assert(input.window_title.len <= model.window_title_template.len);
        @memcpy(model.window_title_template[0..input.window_title.len], input.window_title);
        model.window_title_template_len = @intCast(input.window_title.len);

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
    pub fn barState(model: *const Model) *const bars_capability.State {
        return &model.bars;
    }

    /// Commits one current-generation dynamic block without retaining Lua values.
    ///
    /// ```zig
    /// _ = try model.updateBar(input);
    /// ```
    pub fn updateBar(model: *Model, input: BarUpdateInput) !?BarUpdateCommit {
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
    pub fn setSidebarVisible(model: *Model, visible: bool) ?SidebarLayout {
        return model.commitSidebarLayout(visible, model.sidebar_width);
    }

    /// Toggles the sidebar preference and advances only the chrome revision.
    ///
    /// ```zig
    /// const change = model.toggleSidebar();
    /// ```
    pub fn toggleSidebar(model: *Model) SidebarLayout {
        return model.setSidebarVisible(!model.sidebar_visible).?;
    }

    /// Commits an exact pointer-selected width within current host geometry.
    ///
    /// ```zig
    /// const change = model.setSidebarWidth(70) orelse return;
    /// ```
    pub fn setSidebarWidth(model: *Model, requested_width: u16) ?SidebarLayout {
        const width = frontend_ui.sidebar.clampInteractive(model.host_size.cols, requested_width);

        return model.commitSidebarLayout(model.sidebar_visible, width);
    }

    /// Moves the preferred width by one keybinding step.
    ///
    /// ```zig
    /// const change = model.stepSidebarWidth(.wider) orelse return;
    /// ```
    pub fn stepSidebarWidth(model: *Model, direction: frontend_ui.sidebar.Direction) ?SidebarLayout {
        const width = frontend_ui.sidebar.step(model.host_size.cols, model.sidebar_width, direction);

        return model.commitSidebarLayout(model.sidebar_visible, width);
    }

    /// Restores server-retained sidebar state without losing a preference
    /// merely because the current terminal is temporarily narrow.
    ///
    /// ```zig
    /// const change = model.restoreSidebarLayout(true, 73) orelse return;
    /// ```
    pub fn restoreSidebarLayout(model: *Model, visible: bool, preferred_width: u16) ?SidebarLayout {
        const width = @max(frontend_ui.sidebar.minimum_width, preferred_width);

        return model.commitSidebarLayout(visible, width);
    }

    fn commitSidebarLayout(model: *Model, visible: bool, width: u16) ?SidebarLayout {
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
    pub fn setWorkspaceListCollapsed(model: *Model, collapsed: bool) ?WorkspaceListCollapse {
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
    pub fn toggleWorkspaceList(model: *Model) WorkspaceListCollapse {
        return model.setWorkspaceListCollapsed(!model.workspace_list_collapsed).?;
    }

    /// Commits one newer runtime workspace-list replica atomically. Stale
    /// revisions preserve both the stored snapshot and its model version.
    ///
    /// ```zig
    /// const commit = try model.reconcileWorkspaceList(input) orelse return;
    /// ```
    pub fn reconcileWorkspaceList(model: *Model, input: workspace_list_mod.SnapshotInput) !?WorkspaceListCommit {
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
    pub fn workspaceListSnapshot(model: *const Model) *const workspace_list_mod.Snapshot {
        return &model.workspace_list_snapshot;
    }

    /// Reports whether the latest runtime list contains one workspace.
    ///
    /// ```zig
    /// if (!model.knowsWorkspace(workspace)) return;
    /// ```
    pub fn knowsWorkspace(model: *const Model, workspace: schema.WorkspaceId) bool {
        return model.workspace_list_snapshot.indexOf(workspace) != null;
    }

    /// Resolves one zero-based workspace position from committed client state.
    ///
    /// ```zig
    /// const workspace = model.workspaceAtPosition(0) orelse return;
    /// ```
    pub fn workspaceAtPosition(model: *const Model, position: usize) ?schema.WorkspaceId {
        return model.workspace_list_snapshot.workspaceAtPosition(position);
    }

    /// Commits one changed runtime proxy state. Repeated values produce no
    /// effect or presentation work.
    ///
    /// ```zig
    /// const commit = model.reconcileProxyStatus(true) orelse return;
    /// ```
    pub fn reconcileProxyStatus(model: *Model, active: bool) ?ProxyStatusCommit {
        if (model.proxy_tls_active == active) {
            return null;
        }

        const previous = model.proxy_tls_active;
        const proxy_status_revision_before = model.proxy_status_revision;
        model.proxy_tls_active = active;
        model.proxy_status_revision +%= 1;

        return .{
            .previous = previous,
            .active = active,
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

    /// Commits one newer host-health replica. Invalid newer values preserve
    /// the last usable metrics and their local version.
    ///
    /// ```zig
    /// const commit = try model.reconcileSystemMetrics(metrics) orelse return;
    /// ```
    pub fn reconcileSystemMetrics(model: *Model, metrics: SystemMetrics) !?SystemMetricsCommit {
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
    pub fn systemMetrics(model: *const Model) ?SystemMetrics {
        return model.system_metrics;
    }

    /// Publishes one bounded client notification and advances its isolated
    /// version. The center owns all borrowed text before this call returns.
    ///
    /// ```zig
    /// const publication = model.publishNotification(now_ns, input);
    /// ```
    pub fn publishNotification(model: *Model, now_ns: u64, input: notifications.Input) NotificationPublication {
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
    pub fn notificationSnapshot(model: *const Model) *const notifications.Center {
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
    pub fn advanceNotifications(model: *Model, now_ns: u64) ?NotificationChange {
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
    pub fn activateNotification(model: *Model, id: notifications.Id, now_ns: u64) ?NotificationActivation {
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
    pub fn dismissNotification(model: *Model, id: notifications.Id, now_ns: u64) ?NotificationChange {
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
    pub fn reconcileAgentSnapshot(model: *Model, input: agents.SnapshotInput) !?AgentSnapshotCommit {
        if (input.revision <= model.agent_snapshot.revision) {
            return null;
        }
        if (input.agents.len > agents.max_agents) {
            return error.TooManyAgents;
        }

        var status_changes: AgentStatusChanges = .{};
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
    pub fn agentSnapshot(model: *const Model) *const agents.Snapshot {
        return &model.agent_snapshot;
    }

    /// Returns the window title the focused pane of the active tab last set,
    /// or an empty slice.
    ///
    /// ```zig
    /// const title = model.focusedPaneTitle();
    /// ```
    pub fn focusedPaneTitle(model: *const Model) []const u8 {
        const active = model.workspace.activeConst() orelse return "";
        const pane_id = active.model.layout.focused() orelse return "";
        const pane = active.model.findConst(pane_id) orelse return "";
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
        const active = model.workspace.activeConst() orelse return "";
        const pane = active.model.focusedPaneConst() orelse return "";
        return pane.foregroundName();
    }

    /// Reports whether one exact pane generation is current.
    ///
    /// ```zig
    /// if (!model.knowsAgent(key)) discardNotification();
    /// ```
    pub fn knowsAgent(model: *const Model, key: agents.AgentKey) bool {
        return model.agent_snapshot.find(key) != null;
    }

    /// Returns the focused agent that finished unseen, once per completion,
    /// so the client can acknowledge it. Focus and the snapshot decide; no
    /// version advances.
    ///
    /// ```zig
    /// const key = model.takeAgentAcknowledgement() orelse return;
    /// ```
    pub fn takeAgentAcknowledgement(model: *Model) ?agents.AgentKey {
        const active = model.workspace.activeConst() orelse return null;
        const pane_id = active.model.layout.focused() orelse return null;
        const key = model.agent_snapshot.keyForPane(active.location, pane_id) orelse return null;
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
        return model.agent_snapshot.hasWorkingAgent();
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
    pub fn advanceSidebarAnimation(model: *Model) ?SidebarAnimationChange {
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
    pub fn planAgentNavigation(model: *const Model, key: agents.AgentKey) ?AgentNavigationPlan {
        const agent = model.agent_snapshot.find(key) orelse return null;
        if (model.workspace.tabForPaneConst(key.pane_id)) |tab| {
            const active = model.workspace.activeConst() orelse return null;

            return .{ .local = .{
                .pane_id = key.pane_id,
                .select_tab = if (active.location.tab_id == tab.location.tab_id)
                    null
                else
                    tab.location.tab_id,
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
    /// Unknown providers do not support the local image shelf.
    ///
    /// ```zig
    /// const key = model.focusedAttachmentAgent() orelse return;
    /// ```
    pub fn focusedAttachmentAgent(model: *const Model) ?agents.AgentKey {
        const active = model.workspace.activeConst() orelse return null;
        const pane_id = active.model.layout.focused() orelse return null;
        const key = model.agent_snapshot.keyForPane(active.location, pane_id) orelse return null;
        const agent = model.agent_snapshot.find(key).?;
        switch (agent.provider) {
            .claude, .codex, .pi => return key,
            else => return null,
        }
    }

    /// Resolves the focused attachment-capable agent to its capture target.
    ///
    /// ```zig
    /// const target = model.focusedAttachmentTarget() orelse return;
    /// ```
    pub fn focusedAttachmentTarget(model: *const Model) ?attachments.Target {
        const key = model.focusedAttachmentAgent() orelse return null;

        return .{
            .pane_id = key.pane_id,
            .pane_generation = key.pane_generation,
        };
    }

    /// Resolves the provider only while the exact pane generation still owns
    /// an attachment-capable agent.
    ///
    /// ```zig
    /// const provider = model.attachmentProvider(target) orelse return;
    /// ```
    pub fn attachmentProvider(model: *const Model, target: attachments.Target) ?schema.AgentProvider {
        const agent = model.agent_snapshot.find(.{
            .pane_id = target.pane_id,
            .pane_generation = target.pane_generation,
        }) orelse return null;

        return switch (agent.provider) {
            .claude, .codex, .pi => agent.provider,
            else => null,
        };
    }

    /// Returns the pane identity and reporting mode last synchronized with the
    /// child protocol.
    ///
    /// ```zig
    /// const reported = model.reportedPaneFocus() orelse return;
    /// ```
    pub fn reportedPaneFocus(model: *const Model) ?ReportedPaneFocus {
        return model.reported_pane_focus;
    }

    /// Commits the active focused pane as the protocol-reporting target. The
    /// returned transition names the ordered focus messages, if any.
    ///
    /// ```zig
    /// const transition = model.syncReportedPaneFocus() orelse return;
    /// ```
    pub fn syncReportedPaneFocus(model: *Model) ?PaneFocusReportTransition {
        const current: ?ReportedPaneFocus = current: {
            const active = model.workspace.active() orelse break :current null;
            const pane_id = active.model.layout.focused() orelse break :current null;
            const pane = active.model.find(pane_id) orelse break :current null;

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
    pub fn clearReportedPaneFocus(model: *Model) ?PaneFocusReportTransition {
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
    pub fn releaseReportedPaneFocus(model: *Model, pane_id: schema.PaneId) bool {
        const reported = model.reported_pane_focus orelse return false;
        if (reported.pane_id != pane_id) {
            return false;
        }

        model.reported_pane_focus = null;
        return true;
    }

    fn commitReportedPaneFocus(model: *Model, current: ?ReportedPaneFocus) ?PaneFocusReportTransition {
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
                if (model.workspace.findPane(reported.pane_id)) |pane| {
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
    pub fn panePasteSession(model: *const Model) ?PanePasteSession {
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
    pub fn beginPanePaste(model: *Model) ?PanePasteSession {
        if (model.pane_paste != null) {
            return null;
        }

        const plan = model.planPaneInput(.focused) orelse return null;
        const session: PanePasteSession = .{
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
    pub fn finishPanePaste(model: *Model, session: PanePasteSession) bool {
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
    pub fn releasePanePaste(model: *Model, pane_id: schema.PaneId) bool {
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
    pub fn planPaneInput(model: *const Model, target: PaneInputTarget) ?PaneInputPlan {
        switch (target) {
            .focused, .pane => {
                if (model.name_prompt.active() or model.copy_state != null) {
                    return null;
                }
            },
            .key_lease => {},
            .paste_session => |expected| {
                const active = model.pane_paste orelse return null;
                if (!std.meta.eql(active, expected)) {
                    return null;
                }
            },
        }

        const pane = switch (target) {
            .focused => focused: {
                const active = model.workspace.activeConst() orelse return null;
                break :focused active.model.focusedPaneConst() orelse return null;
            },
            .pane => |pane_id| explicit: {
                const active = model.workspace.activeConst() orelse return null;
                break :explicit active.model.findConst(pane_id) orelse return null;
            },
            .key_lease => |pane_id| leased: {
                const tab = model.workspace.tabForPaneConst(pane_id) orelse return null;
                break :leased tab.model.findConst(pane_id) orelse return null;
            },
            .paste_session => |session| captured: {
                const tab = model.workspace.tabForPaneConst(session.pane_id) orelse return null;
                break :captured tab.model.findConst(session.pane_id) orelse return null;
            },
        };
        if (!pane.attached) {
            return null;
        }

        return .{
            .pane_id = pane.id,
            .input_modes = pane.input_modes,
        };
    }

    /// Applies one attached runtime frame and copy-mode reconciliation as one
    /// client-model commit. Broken patch bases request recovery without
    /// changing state; frames already made stale by detach are ignored.
    ///
    /// ```zig
    /// const outcome = try model.applyPaneFrame(frame);
    /// ```
    pub fn applyPaneFrame(model: *Model, frame: schema.frame.FrameView) !PaneFrameOutcome {
        const tab = model.workspace.tabForPane(frame.pane_id) orelse return error.UnexpectedPane;
        const pane = tab.model.find(frame.pane_id) orelse return error.UnexpectedPane;
        if (!pane.attached) {
            return .detached;
        }
        if (frame.base_frame_id != 0 and frame.base_frame_id != pane.applied_frame_id) {
            return .{ .resync = .{
                .pane_id = frame.pane_id,
                .known_frame_id = pane.applied_frame_id,
            } };
        }

        const previous_scroll_offset = pane.scroll.offset;
        const applied = try tab.model.applyFrame(frame);
        _ = model.reconcileCopyModeFrame(.{
            .pane_id = frame.pane_id,
            .previous_offset = previous_scroll_offset,
            .scroll = frame.scroll,
        });
        model.frame_revision +%= 1;
        const active = model.workspace.activeConst();

        return .{ .applied = .{
            .pane_id = frame.pane_id,
            .location = tab.location,
            .frame_id = frame.frame_id,
            .graphics_visible = frame.scroll.atBottom(frame.rows) and
                active != null and std.meta.eql(active.?.location, tab.location),
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
    pub fn setPaneGraphicsFallback(model: *Model, pane_id: schema.PaneId, visible: bool) ?PaneGraphicsFallbackCommit {
        const tab = model.workspace.tabForPane(pane_id) orelse return null;
        if (!tab.model.setGraphicsPlaceholder(pane_id, visible)) {
            return null;
        }

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
    pub fn updatePaneMetadata(model: *Model, command: PaneMetadataCommand) !?PaneMetadataCommit {
        const pane_id = switch (command) {
            .cwd => |cwd| cwd.pane_id,
            .foreground => |foreground| foreground.pane_id,
            .title => |title| title.pane_id,
        };
        const tab = model.workspace.tabForPane(pane_id) orelse return null;
        const kind = std.meta.activeTag(command);
        const change = switch (command) {
            .cwd => |cwd| try tab.model.setPaneCwd(cwd.pane_id, cwd.path),
            .foreground => |foreground| tab.model.setPaneForeground(foreground.pane_id, foreground.name),
            .title => |title| try tab.model.setPaneTitle(title.pane_id, title.title),
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

    /// Commits one viewport intent for an attached pane in the active tab.
    /// Copy mode owns its viewport transaction while it is active.
    ///
    /// ```zig
    /// const change = model.setPaneViewport(command) orelse return;
    /// ```
    pub fn setPaneViewport(model: *Model, command: PaneViewportCommand) ?PaneViewportChange {
        if (model.copy_state != null) {
            return null;
        }

        const active = model.workspace.active() orelse return null;
        const pane = active.model.find(command.pane_id) orelse return null;
        if (!pane.attached) {
            return null;
        }

        return commitPaneViewport(model, pane, paneViewportOffset(pane, command.target));
    }

    /// Reports whether copy mode currently owns pane input.
    ///
    /// ```zig
    /// if (model.copyModeActive()) return;
    /// ```
    pub fn copyModeActive(model: *const Model) bool {
        return model.copy_state != null;
    }

    /// Returns the pane captured by active copy mode.
    ///
    /// ```zig
    /// const pane_id = model.copyModeTarget() orelse return;
    /// ```
    pub fn copyModeTarget(model: *const Model) ?schema.PaneId {
        const state = model.copy_state orelse return null;

        return state.pane_id;
    }

    /// Returns the immutable copy-mode projection consumed by presenters.
    ///
    /// ```zig
    /// const projection = model.copyModeProjection() orelse return;
    /// ```
    pub fn copyModeProjection(model: *const Model) ?CopyModeProjection {
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
        if (model.copy_state != null or model.name_prompt.active() or model.pane_paste != null) {
            return false;
        }

        const active = model.workspace.active() orelse return false;
        const pane = active.model.focusedPane() orelse return false;
        if (!pane.attached) {
            return false;
        }

        const cursor: copy_mode.Point = if (pane.cursor.visible)
            .{ .x = pane.cursor.x, .y = pane.scroll.offset + pane.cursor.y }
        else
            .{ .x = 0, .y = pane.scroll.offset + pane.buffer.h -| 1 };
        model.copy_state = copy_mode.State.init(pane.id, cursor, pane.scroll.offset);
        model.copy_revision +%= 1;
        return true;
    }

    /// Plans one copy-mode command without mutating state or performing
    /// runtime effects. Missing targets plan a local exit.
    ///
    /// ```zig
    /// const plan = model.planCopyMode(.{ .key = key }) orelse return;
    /// ```
    pub fn planCopyMode(model: *const Model, command: CopyModeCommand) ?CopyModePlan {
        const previous = model.copy_state orelse return null;
        const active = model.workspace.activeConst() orelse return model.planCopyModeExit(previous, null);
        const pane = active.model.findConst(previous.pane_id) orelse
            return model.planCopyModeExit(previous, null);
        var next = previous;

        switch (command) {
            .key => |pressed| {
                const effect = copy_mode.applyKey(&next, pressed, &pane.buffer, pane.scroll);
                if (!effect.handled) {
                    return null;
                }
                if (effect.search) |direction| {
                    return .{
                        .expected_revision = model.copy_revision,
                        .previous = previous,
                        .next = next,
                        .viewport = copyModeViewport(pane, next.viewport_offset),
                        .search = direction,
                    };
                }
                if (effect.exit) {
                    const selection: ?schema.CopySelection = if (effect.copy and next.anchor != null) .{
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
            .vertical => |delta| next.vertical(delta, pane.scroll, pane.buffer.h),
            .matches => |found| {
                if (found.pane_id != previous.pane_id) {
                    return null;
                }

                next.applyMatches(found.matches, pane.scroll, pane.buffer.h);
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
            .viewport = copyModeViewport(pane, next.viewport_offset),
        };
    }

    /// Commits a current copy-mode plan and returns the post-commit runtime
    /// synchronization. Stale plans leave state untouched.
    ///
    /// ```zig
    /// const commit = model.commitCopyMode(plan) orelse return;
    /// ```
    pub fn commitCopyMode(model: *Model, plan: CopyModePlan) ?CopyModeCommit {
        if (model.copy_revision != plan.expected_revision) {
            return null;
        }

        const current = model.copy_state orelse return null;
        if (!std.meta.eql(current, plan.previous)) {
            return null;
        }

        if (plan.next) |next| {
            const active = model.workspace.active() orelse return null;
            if (active.model.find(next.pane_id) == null) {
                return null;
            }
        }

        var viewport_change: ?PaneViewportChange = null;
        if (plan.viewport) |viewport| {
            const active = model.workspace.active() orelse return null;
            const pane = active.model.find(viewport.pane_id) orelse return null;
            if (viewport.offset > pane.scroll.maxOffset(pane.buffer.h)) {
                return null;
            }

            viewport_change = commitPaneViewport(model, pane, viewport.offset);
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
    pub fn releaseCopyMode(model: *Model, pane_id: schema.PaneId) bool {
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
    fn reconcileCopyModeFrame(model: *Model, command: CopyModeFrame) bool {
        const state = model.copy_state orelse return false;
        if (state.pane_id != command.pane_id) {
            return false;
        }

        var next = state;
        copy_mode.onFrame(&next, command.previous_offset, command.scroll);
        if (std.meta.eql(state, next)) {
            return false;
        }

        model.copy_state = next;
        model.copy_revision +%= 1;
        return true;
    }

    fn planCopyModeExit(model: *const Model, previous: copy_mode.State, selection: ?schema.CopySelection) CopyModePlan {
        const pane = if (model.workspace.activeConst()) |active|
            active.model.findConst(previous.pane_id)
        else
            null;
        const viewport = if (pane) |target|
            copyModeViewport(target, previous.entry_offset)
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
    pub fn activeTabLocation(model: *const Model) ?schema.TabLocation {
        const active = model.workspace.activeConst() orelse return null;

        return active.location;
    }

    /// Returns the runtime workspace currently projected by this client.
    ///
    /// ```zig
    /// const workspace = model.workspaceLocation() orelse return;
    /// ```
    pub fn workspaceLocation(model: *const Model) ?schema.WorkspaceLocation {
        return model.workspace.workspace;
    }

    /// Resolves one tab identity inside the currently observed workspace.
    ///
    /// ```zig
    /// const location = model.tabLocation(tab_id) orelse return;
    /// ```
    pub fn tabLocation(model: *const Model, tab_id: schema.TabId) ?schema.TabLocation {
        const index = model.workspace.indexOf(tab_id) orelse return null;

        return model.workspace.items[index].?.location;
    }

    /// Returns the attached focused pane that may authorize a new workspace
    /// launch, without changing client state.
    ///
    /// ```zig
    /// const pane_id = model.planWorkspaceCreation() orelse return;
    /// ```
    pub fn planWorkspaceCreation(model: *const Model) ?schema.PaneId {
        return (focusedLaunchSource(model) orelse return null).pane_id;
    }

    /// Captures the current workspace and attached focused pane for a tab
    /// creation request without changing client state.
    ///
    /// ```zig
    /// const plan = model.planTabCreation() orelse return;
    /// ```
    pub fn planTabCreation(model: *const Model) ?TabCreationPlan {
        const source = focusedLaunchSource(model) orelse return null;

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
    pub fn departWorkspace(model: *Model) WorkspaceDeparture {
        const departure = captureWorkspace(model);
        if (departure.source == null) {
            releaseInvalidCopyMode(model);
            return departure;
        }

        const active = model.workspace.activeConst();
        const had_tabs = model.workspace.count != 0;
        const had_active = active != null;
        const had_visible_panes = if (active) |tab| tab.model.pane_count != 0 else false;
        model.workspace.deinit();
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
        releaseInvalidCopyMode(model);

        return departure;
    }

    /// Builds the confirmed root tab transactionally inside an empty client
    /// model. Construction failure preserves the empty model and every
    /// version.
    ///
    /// ```zig
    /// const activation = try model.arriveWorkspace(arrival);
    /// ```
    pub fn arriveWorkspace(model: *Model, arrival: WorkspaceArrival) !WorkspaceActivation {
        if (model.workspace.count != 0 or model.workspace.workspace != null) {
            return error.ModelNotEmpty;
        }

        const version_before = model.version();
        try model.workspace.bootstrap(arrival.pane_id, arrival.location, arrival.size);
        if (arrival.saved_layout) |saved| {
            std.debug.assert(model.workspace.restoreLayoutOnNextSnapshot(arrival.location, saved));
        }

        model.workspace_revision +%= 1;
        model.tabs_revision +%= 1;
        model.active_tab_revision +%= 1;
        model.panes_revision +%= 1;
        releaseInvalidCopyMode(model);

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
    pub fn replaceWorkspace(model: *Model, arrival: WorkspaceArrival) !WorkspaceReplacement {
        const departure = captureWorkspace(model);
        const version_before = model.version();
        if (departure.source) |source| {
            if (std.meta.eql(source, arrival.location.workspace)) {
                return error.WorkspaceAlreadyActive;
            }
        }

        try model.workspace.replaceWithRoot(.{
            .pane_id = arrival.pane_id,
            .location = arrival.location,
            .size = arrival.size,
        });
        if (arrival.saved_layout) |saved| {
            std.debug.assert(model.workspace.restoreLayoutOnNextSnapshot(arrival.location, saved));
        }

        model.workspace_revision +%= 1;
        model.tabs_revision +%= 1;
        model.active_tab_revision +%= 1;
        model.panes_revision +%= 1;
        releaseInvalidCopyMode(model);

        return .{
            .departure = departure,
            .activation = model.workspaceActivation(.{
                .pane_id = arrival.pane_id,
                .location = arrival.location,
                .version_before = version_before,
            }),
        };
    }

    fn workspaceActivation(model: *const Model, seed: WorkspaceActivationSeed) WorkspaceActivation {
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
    pub fn reconcileWorkspace(model: *Model, snapshot: WorkspaceSnapshot) !WorkspaceReconciliation {
        const current_workspace = model.workspace.workspace orelse return error.UnexpectedWorkspace;
        if (!std.meta.eql(current_workspace, snapshot.workspace)) {
            return error.UnexpectedWorkspace;
        }

        if (snapshot.tabs.len == 0) {
            return error.WorkspaceHasNoTabs;
        }

        if (snapshot.tabs.len > tabs_mod.max_tabs) {
            return error.TabLimitReached;
        }

        if (snapshot.name.len == 0 or snapshot.name.len > schema.max_workspace_name_bytes) {
            return error.InvalidWorkspaceName;
        }

        const previous_active = model.activeTabLocation() orelse return error.NoActiveTab;
        var reconciliation: WorkspaceReconciliation = .{
            .previous_active = previous_active,
            .active = previous_active,
            .workspace_changed = !std.mem.eql(u8, model.workspace.workspaceName(), snapshot.name),
            .tabs_changed = snapshot.tabs.len != model.workspace.count,
        };
        var canonical_tabs: [tabs_mod.max_tabs]schema.TabId = undefined;
        for (snapshot.tabs, 0..) |descriptor, index| {
            canonical_tabs[index] = descriptor.tab_id;
            if (index >= model.workspace.count) {
                reconciliation.tabs_changed = true;
            } else {
                const current = &model.workspace.items[index].?;
                if (current.location.tab_id != descriptor.tab_id or
                    !std.mem.eql(u8, current.labelSlice(), descriptor.label))
                {
                    reconciliation.tabs_changed = true;
                }
            }
        }

        var tabs = model.workspace.tabIterator();
        while (tabs.next()) |tab| {
            if (std.mem.findScalar(schema.TabId, canonical_tabs[0..snapshot.tabs.len], tab.location.tab_id) != null) {
                continue;
            }

            reconciliation.removed_tabs.append(tab.location);
            var panes = tab.model.paneIterator();
            while (panes.next()) |pane| {
                reconciliation.removed_panes.append(pane.id);
            }
        }

        try model.workspace.reconcileWorkspace(snapshot);
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
        releaseInvalidCopyMode(model);

        const active = model.workspace.activeConst() orelse return error.WorkspaceHasNoTabs;
        reconciliation.active_snapshot_loaded = active.snapshot_loaded;
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
    pub fn reconcileTab(model: *Model, snapshot: TabSnapshot, area: ui.Rect) !TabReconciliation {
        const tab = model.workspace.find(snapshot.location.tab_id) orelse return error.UnexpectedTab;
        if (!std.meta.eql(tab.location, snapshot.location)) {
            return error.UnexpectedTab;
        }

        if (snapshot.panes.len > schema.max_panes_per_tab) {
            return error.TooManyPanes;
        }

        for (snapshot.panes, 0..) |pane_id, index| {
            if (std.mem.findScalar(schema.PaneId, snapshot.panes[0..index], pane_id) != null) {
                return error.DuplicatePane;
            }

            const existing = model.workspace.findPane(pane_id);
            if (existing != null and !std.meta.eql(existing.?.location, snapshot.location)) {
                return error.PaneAlreadyExists;
            }
        }

        const active_location = model.activeTabLocation() orelse return error.NoActiveTab;
        const active = std.meta.eql(active_location, snapshot.location);
        const previous_layout_revision = tab.model.layout.currentRevision();
        var reconciliation: TabReconciliation = .{
            .location = snapshot.location,
            .area = area,
            .active = active,
            .panes_changed = false,
        };
        var panes = tab.model.paneIterator();
        while (panes.next()) |pane| {
            if (std.mem.findScalar(schema.PaneId, snapshot.panes, pane.id) == null) {
                reconciliation.removed_panes.append(pane.id);
            }
        }

        const reconciled = try model.workspace.reconcileTab(snapshot, area);
        reconciliation.panes_changed = reconciled.model.layout.currentRevision() != previous_layout_revision;
        if (reconciliation.active and reconciliation.panes_changed) {
            model.panes_revision +%= 1;
        }

        reconciliation.snapshot_loaded = reconciled.snapshot_loaded;
        reconciliation.layout_revision = reconciled.model.layout.currentRevision();
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
    pub fn confirmPaneAttachment(model: *Model, attachment: PaneAttachment) PaneAttachmentConfirmation {
        const active = model.workspace.active() orelse return .stale;
        if (!std.meta.eql(active.location, attachment.location)) {
            return .stale;
        }

        const pane = active.model.find(attachment.pane_id) orelse return .stale;
        if (!std.meta.eql(pane.location, attachment.location) or pane.attached) {
            return .stale;
        }

        active.model.markAttached(attachment.pane_id) catch unreachable;
        return .confirmed;
    }

    /// Reports whether the active client replica still needs the requested
    /// attachment. Stale tabs, missing panes and confirmed panes need no repair.
    ///
    /// ```zig
    /// if (model.needsPaneAttachment(attachment)) requestSnapshot();
    /// ```
    pub fn needsPaneAttachment(model: *const Model, attachment: PaneAttachment) bool {
        const active = model.workspace.activeConst() orelse return false;
        if (!std.meta.eql(active.location, attachment.location)) {
            return false;
        }

        const pane = active.model.findConst(attachment.pane_id) orelse return false;
        return std.meta.eql(pane.location, attachment.location) and !pane.attached;
    }

    /// Captures one exact tab's operational attachments and whether it owns
    /// the current paste or reported focus authority.
    ///
    /// ```zig
    /// const plan = try model.planTabDetachment(location);
    /// ```
    pub fn planTabDetachment(model: *const Model, location: schema.TabLocation) !TabDetachmentPlan {
        const tab = findTabConst(&model.workspace, location) orelse return error.UnexpectedTab;
        var plan: TabDetachmentPlan = .{ .location = location };

        for (&tab.model.panes) |*slot| {
            const pane = if (slot.*) |*value| value else continue;
            plan.panes[plan.len] = .{
                .pane_id = pane.id,
                .attached = pane.attached,
            };
            plan.len += 1;
        }

        if (model.pane_paste) |session| {
            if (tab.model.findConst(session.pane_id) != null) {
                plan.owns_paste = true;
                plan.paste_marker_required = session.bracketed_paste;
            }
        }

        if (model.reported_pane_focus) |reported| {
            if (tab.model.findConst(reported.pane_id)) |pane| {
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
    pub fn commitTabDetachment(model: *Model, plan: TabDetachmentPlan) !void {
        if (plan.len > multiplexer.max_panes) {
            return error.InvalidTabDetachment;
        }

        const tab = findTab(&model.workspace, plan.location) orelse return error.StaleTabDetachment;
        if (tab.model.pane_count != plan.len) {
            return error.StaleTabDetachment;
        }

        for (plan.slice(), 0..) |planned, index| {
            for (plan.slice()[0..index]) |previous| {
                if (previous.pane_id == planned.pane_id) {
                    return error.InvalidTabDetachment;
                }
            }

            const pane = tab.model.find(planned.pane_id) orelse return error.StaleTabDetachment;
            if (pane.attached != planned.attached) {
                return error.StaleTabDetachment;
            }
        }

        for (plan.slice()) |planned| {
            detachPane(tab.model.find(planned.pane_id).?);
        }
    }

    /// Changes focus inside the active tab and reports the committed identity
    /// and pane revision. Repeated, missing and directionless targets leave
    /// every version intact.
    ///
    /// ```zig
    /// const focus = model.focusPane(.{ .target = .{ .direction = .left }, .area = area }) orelse return;
    /// ```
    pub fn focusPane(model: *Model, request: PaneFocusRequest) ?PaneFocus {
        const active = model.workspace.active() orelse return null;
        const previous = active.model.layout.focused() orelse return null;
        const focused = switch (request.target) {
            .pane_id => |pane_id| focused: {
                if (pane_id == previous or !active.model.focusPane(pane_id)) {
                    return null;
                }

                break :focused pane_id;
            },
            .direction => |direction| active.model.focusDirection(direction, request.area) orelse return null,
        };
        std.debug.assert(focused != previous);

        model.panes_revision +%= 1;

        return .{
            .location = active.location,
            .previous = previous,
            .focused = focused,
            .geometry_changed = active.model.layout.isFullscreen(),
            .panes_revision = model.panes_revision,
        };
    }

    /// Moves the nearest split edge around the focused pane and reports the
    /// committed pane revision. Missing axes and constrained edges are no-ops.
    ///
    /// ```zig
    /// const resize = model.resizePane(.{ .direction = .right, .area = area }) orelse return;
    /// ```
    pub fn resizePane(model: *Model, request: ResizePaneRequest) ?PaneGeometryChange {
        const active = model.workspace.active() orelse return null;
        const focused = active.model.layout.focused() orelse return null;
        if (!active.model.resizeFocused(request.direction, request.area)) {
            return null;
        }

        model.panes_revision +%= 1;

        return .{
            .location = active.location,
            .focused = focused,
            .panes_revision = model.panes_revision,
            .area = request.area,
            .fullscreen = active.model.layout.isFullscreen(),
        };
    }

    /// Toggles fullscreen for the focused pane without discarding tiled
    /// geometry. Tabs with fewer than two panes leave every version intact.
    ///
    /// ```zig
    /// const change = model.togglePaneFullscreen(.{ .area = area }) orelse return;
    /// ```
    pub fn togglePaneFullscreen(model: *Model, request: TogglePaneFullscreenRequest) ?PaneGeometryChange {
        const active = model.workspace.active() orelse return null;
        const focused = active.model.layout.focused() orelse return null;
        if (!active.model.toggleFullscreen()) {
            return null;
        }

        model.panes_revision +%= 1;

        return .{
            .location = active.location,
            .focused = focused,
            .panes_revision = model.panes_revision,
            .area = request.area,
            .fullscreen = active.model.layout.isFullscreen(),
        };
    }

    /// Plans one split from active client state without changing the semantic
    /// model. Both provisional sizes inherit the current cell pixel geometry.
    ///
    /// ```zig
    /// const plan = model.planPaneSplit(.{ .axis = .horizontal, .area = area }) orelse return;
    /// ```
    pub fn planPaneSplit(model: *Model, request: RequestPaneSplit) ?PaneSplitPlan {
        const active = model.workspace.active() orelse return null;
        const focused = active.model.focusedPane() orelse return null;
        if (!focused.attached or !std.meta.eql(focused.location, active.location)) {
            return null;
        }

        const restore_size = active.model.contentSize(focused.id, request.area) orelse return null;
        const prospective = active.model.prospectiveSplit(focused.id, request.axis, request.area) orelse
            return null;
        var provisional_size = multiplexer.rectSize(prospective.existing_content) orelse return null;
        var new_pane_size = multiplexer.rectSize(prospective.new_content) orelse return null;
        inheritCellSize(&provisional_size, restore_size);
        inheritCellSize(&new_pane_size, restore_size);

        return .{
            .split = .{
                .target_pane = focused.id,
                .location = active.location,
                .axis = request.axis,
                .area = request.area,
            },
            .provisional_resize = .{ .pane_id = focused.id, .size = provisional_size },
            .restore_resize = .{ .pane_id = focused.id, .size = restore_size },
            .new_pane_size = new_pane_size,
        };
    }

    /// Commits a runtime-created pane into the exact tab that requested it.
    /// A missing target is a recoverable race; a missing tab leaves the pane
    /// unrepresented so the client adapter can detach its runtime attachment.
    ///
    /// ```zig
    /// const commit = try model.commitPaneSplit(command);
    /// ```
    pub fn commitPaneSplit(model: *Model, command: CommitPaneSplit) !PaneSplitCommit {
        const stale = model.finishPaneSplit(command, .{
            .disposition = .stale,
            .change = .unchanged,
            .layout_revision = 0,
        });
        const workspace = model.workspace.workspace orelse return stale;
        if (!std.meta.eql(workspace, command.split.location.workspace)) {
            return stale;
        }

        const tab = findTab(&model.workspace, command.split.location) orelse return stale;
        const active = if (model.workspace.activeConst()) |current|
            std.meta.eql(current.location, command.split.location)
        else
            false;
        if (model.workspace.tabForPane(command.new_pane)) |owner| {
            if (owner != tab or command.new_pane == command.split.target_pane) {
                return error.PaneAlreadyExists;
            }

            const pane = tab.model.find(command.new_pane).?;
            if (active) {
                try tab.model.markAttached(command.new_pane);
            } else {
                detachPane(pane);
            }

            return model.finishPaneSplit(command, .{
                .disposition = if (active) .active else .inactive,
                .change = .unchanged,
                .layout_revision = tab.model.layout.currentRevision(),
            });
        }

        if (tab.model.find(command.split.target_pane) != null) {
            try tab.model.split(
                command.split.target_pane,
                command.new_pane,
                command.split.location,
                command.split.axis,
                command.split.area,
            );
        } else {
            try tab.model.addDiscovered(command.new_pane, command.split.location, command.split.area);
            try tab.model.markAttached(command.new_pane);
        }

        if (!active) {
            detachPane(tab.model.find(command.new_pane).?);
        } else {
            model.panes_revision +%= 1;
        }

        return model.finishPaneSplit(command, .{
            .disposition = if (active) .active else .inactive,
            .change = if (active) .changed else .unchanged,
            .layout_revision = tab.model.layout.currentRevision(),
        });
    }

    fn finishPaneSplit(model: *const Model, command: CommitPaneSplit, state: PaneSplitCommitState) PaneSplitCommit {
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
    pub fn recoverPaneSplit(model: *Model, command: RecoverPaneSplit) PaneSplitRecovery {
        const workspace = model.workspace.workspace orelse return .stale;
        if (!std.meta.eql(workspace, command.split.location.workspace)) {
            return .stale;
        }

        const tab = findTab(&model.workspace, command.split.location) orelse return .stale;
        const pane = tab.model.find(command.split.target_pane) orelse return .stale;
        if (!std.meta.eql(pane.location, command.split.location)) {
            return .stale;
        }

        const active = model.workspace.activeConst() orelse return .stale;
        if (!std.meta.eql(active.location, command.split.location) or !pane.attached) {
            return .not_required;
        }

        const size = tab.model.contentSize(command.split.target_pane, command.area) orelse
            return .not_required;
        return .{ .resize = .{ .pane_id = command.split.target_pane, .size = size } };
    }

    /// Resolves the active attached pane that an explicit close request may
    /// target without changing client state.
    ///
    /// ```zig
    /// const closure = model.planPaneClosure() orelse return;
    /// ```
    pub fn planPaneClosure(model: *const Model) ?PaneClosure {
        const active = model.workspace.activeConst() orelse return null;
        const focused = active.model.focusedPaneConst() orelse return null;
        if (!focused.attached or !std.meta.eql(focused.location, active.location)) {
            return null;
        }

        return .{ .pane_id = focused.id, .location = active.location };
    }

    /// Applies one authoritative pane exit. Missing identities are stale
    /// lifecycle traffic and leave every presentation revision unchanged.
    ///
    /// ```zig
    /// const transition = model.retirePane(pane_id);
    /// ```
    pub fn retirePane(model: *Model, pane_id: schema.PaneId) PaneExit {
        const tab = model.workspace.tabForPane(pane_id) orelse return model.stalePaneExit(pane_id);
        const pane = tab.model.find(pane_id) orelse return model.stalePaneExit(pane_id);
        if (!std.meta.eql(pane.location, tab.location)) {
            return model.stalePaneExit(pane_id);
        }

        const active = if (model.workspace.activeConst()) |current|
            std.meta.eql(current.location, tab.location)
        else
            false;
        const location = tab.location;
        std.debug.assert(tab.model.removePane(pane_id));
        if (active) {
            model.panes_revision +%= 1;
        }

        return .{ .retired = .{
            .pane_id = pane_id,
            .location = location,
            .active = active,
            .tab_empty = tab.model.pane_count == 0,
            .layout_revision = tab.model.layout.currentRevision(),
            .workspace_revision = model.workspace_revision,
            .tabs_revision = model.tabs_revision,
            .active_tab_revision = model.active_tab_revision,
            .panes_revision = model.panes_revision,
        } };
    }

    fn stalePaneExit(model: *const Model, pane_id: schema.PaneId) PaneExit {
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
    pub fn applyTabPosition(model: *Model, location: schema.TabLocation, position: u16) !Change {
        const current_workspace = model.workspace.workspace orelse return error.UnexpectedWorkspace;
        if (!std.meta.eql(current_workspace, location.workspace)) {
            return error.UnexpectedWorkspace;
        }

        const change = try model.workspace.applyPosition(location.tab_id, position);
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
    pub fn renameTab(model: *Model, command: RenameTab) !Change {
        const current_workspace = model.workspace.workspace orelse return error.UnexpectedWorkspace;
        if (!std.meta.eql(current_workspace, command.location.workspace)) {
            return error.UnexpectedWorkspace;
        }

        const change = try model.workspace.applyLabel(command.location.tab_id, command.label);
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
    pub fn createTab(model: *Model, command: NewTab) !TabCreation {
        const previous = model.workspace.activeConst() orelse return error.NoActiveTab;
        const previous_location = previous.location;
        const previous_layout_revision = previous.model.layout.currentRevision();
        const tabs_revision_before = model.tabs_revision;
        const active_tab_revision_before = model.active_tab_revision;
        const copy_revision_before = model.copy_revision;

        const created = try model.workspace.addCreated(command.created, command.size);
        model.tabs_revision +%= 1;
        model.active_tab_revision +%= 1;
        releaseInvalidCopyMode(model);

        return .{
            .previous = previous_location,
            .created = command.created.location,
            .created_root_pane_id = command.created.root_pane_id,
            .created_position = command.created.position,
            .previous_layout_revision = previous_layout_revision,
            .created_layout_revision = created.model.layout.currentRevision(),
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
    pub fn removeTab(model: *Model, command: RemoveTab) !TabRemovalCommit {
        const workspace = model.workspace.workspace orelse
            return model.staleTabRemoval(command.location, .workspace);
        if (!std.meta.eql(workspace, command.location.workspace)) {
            return model.staleTabRemoval(command.location, .workspace);
        }

        const closing = model.workspace.find(command.location.tab_id) orelse
            return model.staleTabRemoval(command.location, .tab);
        if (!std.meta.eql(closing.location, command.location)) {
            return error.UnexpectedTab;
        }

        const workspace_removed = model.workspace.count == 1;
        if (workspace_removed != command.workspace_removed) {
            return error.UnexpectedWorkspaceRemoval;
        }

        const was_active = model.workspace.active_index ==
            model.workspace.indexOf(command.location.tab_id).?;
        const active_tab_revision_before = model.active_tab_revision;
        var panes: RemovedPanes = .{};
        var iterator = closing.model.paneIterator();
        while (iterator.next()) |pane| {
            panes.append(pane.id);
        }

        std.debug.assert(model.workspace.remove(command.location.tab_id));
        const active = if (model.workspace.activeConst()) |tab| tab.location else null;
        model.tabs_revision +%= 1;
        if (was_active) {
            model.active_tab_revision +%= 1;
        }
        releaseInvalidCopyMode(model);

        return .{ .removed = .{
            .removed = command.location,
            .panes = panes,
            .was_active = was_active,
            .active = active,
            .workspace_removed = workspace_removed,
            .active_layout_revision = if (model.workspace.activeConst()) |tab|
                tab.model.layout.currentRevision()
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

    fn staleTabRemoval(model: *const Model, location: schema.TabLocation, absence: TabRemovalAbsence) TabRemovalCommit {
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
    pub fn selectTab(model: *Model, target: TabSelectionTarget) !?TabSelection {
        const previous = model.workspace.activeConst() orelse return error.NoActiveTab;

        const changed = switch (target) {
            .tab_id => |tab_id| changed: {
                const position = model.workspace.indexOf(tab_id) orelse return error.TabNotFound;

                break :changed model.workspace.selectPosition(position);
            },
            .offset => |offset| model.workspace.selectOffset(offset),
            .position => |position| model.workspace.selectPosition(position),
        };
        if (!changed) {
            return null;
        }

        const selected = model.workspace.activeConst().?;
        model.active_tab_revision +%= 1;
        releaseInvalidCopyMode(model);

        return .{
            .previous = previous.location,
            .selected = selected.location,
            .previous_layout_revision = previous.model.layout.currentRevision(),
            .selected_layout_revision = selected.model.layout.currentRevision(),
            .workspace_revision = model.workspace_revision,
            .tabs_revision = model.tabs_revision,
            .active_tab_revision = model.active_tab_revision,
            .panes_revision = model.panes_revision,
            .copy_revision = model.copy_revision,
        };
    }
};

fn paneViewportOffset(pane: *const multiplexer.Pane, target: PaneViewportTarget) u32 {
    const maximum = pane.scroll.maxOffset(pane.buffer.h);

    return switch (target) {
        .absolute => |offset| @min(offset, maximum),
        .relative => |delta| @intCast(std.math.clamp(
            @as(i64, pane.scroll.offset) + @as(i64, delta),
            0,
            @as(i64, maximum),
        )),
        .bottom => maximum,
    };
}

fn commitPaneViewport(model: *Model, pane: *multiplexer.Pane, offset: u32) ?PaneViewportChange {
    if (pane.scroll.offset == offset) {
        return null;
    }

    pane.scroll.offset = offset;
    model.viewport_revision +%= 1;

    return .{
        .pane_id = pane.id,
        .offset = offset,
        .at_bottom = pane.scroll.atBottom(pane.buffer.h),
        .viewport_revision = model.viewport_revision,
    };
}

fn copyModeViewport(pane: *const multiplexer.Pane, wanted: u32) ?schema.SetPaneViewport {
    const offset = paneViewportOffset(pane, .{ .absolute = wanted });
    if (pane.scroll.offset == offset) {
        return null;
    }

    return .{ .pane_id = pane.id, .offset = offset };
}

fn releaseInvalidCopyMode(model: *Model) void {
    const state = model.copy_state orelse return;
    const active = model.workspace.activeConst() orelse {
        _ = model.releaseCopyMode(state.pane_id);
        return;
    };
    if (active.model.findConst(state.pane_id) != null) {
        return;
    }

    _ = model.releaseCopyMode(state.pane_id);
}

fn captureWorkspace(model: *Model) WorkspaceDeparture {
    const source = model.workspace.workspace orelse return .{};
    var departure: WorkspaceDeparture = .{ .source = source };
    if (model.workspace.activeConst()) |tab| {
        if (tab.model.focusedPaneConst()) |pane| {
            departure.bookmark = .{
                .location = tab.location,
                .pane_id = pane.id,
                .tab_layout = tab.model.layout,
            };
        }
    }

    var tabs = model.workspace.tabIterator();
    while (tabs.next()) |tab| {
        var panes = tab.model.paneIterator();
        while (panes.next()) |pane| {
            departure.panes.append(pane.id);
        }
    }

    return departure;
}

const LaunchSource = struct {
    location: schema.TabLocation,
    pane_id: schema.PaneId,
};

fn focusedLaunchSource(model: *const Model) ?LaunchSource {
    const active = model.workspace.activeConst() orelse return null;
    const pane = active.model.focusedPaneConst() orelse return null;
    if (!pane.attached or !std.meta.eql(pane.location, active.location)) {
        return null;
    }

    return .{ .location = active.location, .pane_id = pane.id };
}

fn inheritCellSize(size: *schema.TerminalSize, source: schema.TerminalSize) void {
    size.cell_width_px = source.cell_width_px;
    size.cell_height_px = source.cell_height_px;
}

fn detachPane(pane: *multiplexer.Pane) void {
    pane.attached = false;
    pane.pending_frame_id = 0;
}

fn findTab(workspace: *tabs_mod.Model, location: schema.TabLocation) ?*tabs_mod.Tab {
    const tab = workspace.find(location.tab_id) orelse return null;
    if (!std.meta.eql(tab.location, location)) {
        return null;
    }

    return tab;
}

fn findTabConst(workspace: *const tabs_mod.Model, location: schema.TabLocation) ?*const tabs_mod.Tab {
    const index = workspace.indexOf(location.tab_id) orelse return null;
    const tab = &workspace.items[index].?;
    if (!std.meta.eql(tab.location, location)) {
        return null;
    }

    return tab;
}

test "copy mode frame reconciliation and pane release are exact" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 20, .rows = 5 });
    const pane = model.workspace.findPane(pane_id).?;
    pane.scroll = .{ .total_rows = 15, .offset = 10 };
    pane.cursor = .{ .visible = true, .x = 2, .y = 4 };
    try std.testing.expect(model.enterCopyMode());
    const version = model.version();

    try std.testing.expect(!model.reconcileCopyModeFrame(.{
        .pane_id = @enumFromInt(2),
        .previous_offset = 10,
        .scroll = .{ .total_rows = 10, .offset = 5 },
    }));
    try std.testing.expect(model.reconcileCopyModeFrame(.{
        .pane_id = pane_id,
        .previous_offset = 10,
        .scroll = .{ .total_rows = 10, .offset = 5 },
    }));

    try std.testing.expectEqual(version.copy + 1, model.version().copy);
    try std.testing.expectEqual(@as(u32, 9), model.copyModeProjection().?.view.cursor.y);
    try std.testing.expect(!model.reconcileCopyModeFrame(.{
        .pane_id = pane_id,
        .previous_offset = 5,
        .scroll = .{ .total_rows = 10, .offset = 5 },
    }));
    try std.testing.expect(!model.releaseCopyMode(@enumFromInt(2)));
    try std.testing.expect(model.releaseCopyMode(pane_id));
    try std.testing.expect(!model.copyModeActive());
    try std.testing.expectEqual(version.copy + 2, model.version().copy);
}
