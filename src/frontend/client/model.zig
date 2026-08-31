//! Passive state owned by one disposable client.

const std = @import("std");
const core = @import("telar-core");
const agents = @import("../agents/root.zig");
const attachments = @import("../attachments/root.zig");
const lua_config = @import("../config/root.zig");
const graphics = @import("../graphics/root.zig");
const input_capability = @import("../input/root.zig");
const notifications = @import("../notifications/root.zig");
const name_prompt = @import("name_prompt.zig");
const workspace_capability = @import("../workspace/root.zig");

const copy_mode = input_capability.copy_mode;
const keybind = input_capability.keybind;
const kitty = graphics.kitty;
const schema = core.schema;
const layout_mod = workspace_capability.layout;
const multiplexer = workspace_capability.multiplexer;
const tabs_mod = workspace_capability.tabs;
const workspace_list_mod = workspace_capability.workspace_list;
const ui = core.ui;

pub const Version = struct {
    workspace: u64 = 0,
    configuration: u64 = 0,
    diagnostic: u64 = 0,
    host: u64 = 0,
    host_capabilities: u64 = 0,
    workspace_list: u64 = 0,
    agents: u64 = 0,
    sidebar_animation: u64 = 0,
    proxy_status: u64 = 0,
    system_metrics: u64 = 0,
    notifications: u64 = 0,
    tabs: u64 = 0,
    active_tab: u64 = 0,
    panes: u64 = 0,
    frame: u64 = 0,
    pane_metadata: u64 = 0,
    pane_foreground: u64 = 0,
    pane_graphics: u64 = 0,
    chrome: u64 = 0,
    prompt: u64 = 0,
    copy: u64 = 0,
    viewport: u64 = 0,
};

pub const Change = enum {
    unchanged,
    changed,
};

pub const TabSelection = struct {
    previous: schema.TabLocation,
    selected: schema.TabLocation,
};

pub const TabSelectionTarget = union(enum) {
    tab_id: schema.TabId,
    offset: isize,
    position: usize,
};

pub const RenameTab = struct {
    location: schema.TabLocation,
    /// Borrowed only for the synchronous transition.
    label: []const u8,
};

pub const NewTab = struct {
    created: tabs_mod.CreatedTab,
    size: schema.TerminalSize,
};

pub const TabCreation = struct {
    previous: schema.TabLocation,
    created: schema.TabLocation,
};

pub const TabCreationPlan = struct {
    workspace: schema.WorkspaceLocation,
    cwd_source: schema.PaneId,
};

pub const WorkspaceBookmark = struct {
    location: schema.TabLocation,
    pane_id: schema.PaneId,
    tab_layout: layout_mod.Layout,
};

pub const WorkspaceDeparture = struct {
    source: ?schema.WorkspaceLocation = null,
    bookmark: ?WorkspaceBookmark = null,
    panes: RemovedWorkspacePanes = .{},
};

pub const WorkspaceArrival = struct {
    pane_id: schema.PaneId,
    location: schema.TabLocation,
    size: schema.TerminalSize,
    saved_layout: ?layout_mod.Layout = null,
};

pub const WorkspaceReplacement = struct {
    departure: WorkspaceDeparture,
    pane_id: schema.PaneId,
    location: schema.TabLocation,
};

pub const PaneAttachment = struct {
    pane_id: schema.PaneId,
    location: schema.TabLocation,
};

pub const PaneAttachmentConfirmation = enum {
    confirmed,
    stale,
};

pub const PaneFocusTarget = union(enum) {
    pane_id: schema.PaneId,
    direction: layout_mod.Direction,
};

pub const PaneFocusRequest = struct {
    target: PaneFocusTarget,
    area: ui.Rect,
};

pub const PaneFocus = struct {
    location: schema.TabLocation,
    previous: schema.PaneId,
    focused: schema.PaneId,
    geometry_changed: bool,
};

pub const ReportedPaneFocus = struct {
    pane_id: schema.PaneId,
    focus_events: bool,
};

pub const PaneFocusReportTransition = struct {
    previous: ?ReportedPaneFocus,
    current: ?ReportedPaneFocus,
    focus_out: ?schema.PaneId = null,
    focus_in: ?schema.PaneId = null,
};

pub const ResizePaneRequest = struct {
    direction: layout_mod.Direction,
    area: ui.Rect,
};

pub const PaneGeometryChange = struct {
    location: schema.TabLocation,
    focused: schema.PaneId,
    panes_revision: u64,
    area: ui.Rect,
    fullscreen: bool,
};

pub const TogglePaneFullscreenRequest = struct {
    area: ui.Rect,
};

pub const SidebarVisibility = struct {
    visible: bool,
    chrome_revision: u64,
};

pub const SidebarAnimationChange = struct {
    frame: u8,
    sidebar_animation_revision: u64,
};

pub const ConfigurationInput = struct {
    generation: u64,
    sidebar_visible: bool,
    pane_gaps: bool,
};

pub const ConfigurationCommit = struct {
    generation: u64,
    configuration_revision: u64,
    sidebar: ?SidebarVisibility,
    pane_gaps_changed: bool,
    panes_revision: u64,
};

pub const PluginExecutionId = enum(u64) {
    none = 0,
    _,
};

pub const PluginExecution = struct {
    id: PluginExecutionId,
    configuration_generation: u64,
};

pub const ClipboardCaptureId = enum(u64) {
    none = 0,
    _,
};

pub const ClipboardCapture = struct {
    id: ClipboardCaptureId,
    target: attachments.Target,
};

pub const InitialClientState = struct {
    pane_gaps: bool,
    configuration_generation: u64 = 0,
    host_size: schema.TerminalSize = .{ .cols = 80, .rows = 24 },
    host_capabilities: HostCapabilities = .{},
};

pub const HostCapabilities = struct {
    kitty_graphics: kitty.Support = .unknown,
    kitty_zlib: kitty.Support = .unknown,
    window_width_px: u32 = 0,
    window_height_px: u32 = 0,
    cell_width_px: u32 = 0,
    cell_height_px: u32 = 0,
    mouse_pixels: kitty.Support = .unknown,

    /// Resolves one cell size, preferring the host's explicit cell report.
    ///
    /// ```zig
    /// const cell_size = capabilities.cellSize(80, 24);
    /// ```
    pub fn cellSize(capabilities: *const HostCapabilities, cols: u16, rows: u16) struct { width: u16, height: u16 } {
        const width = if (capabilities.cell_width_px != 0)
            capabilities.cell_width_px
        else if (cols != 0)
            capabilities.window_width_px / cols
        else
            0;
        const height = if (capabilities.cell_height_px != 0)
            capabilities.cell_height_px
        else if (rows != 0)
            capabilities.window_height_px / rows
        else
            0;

        return .{
            .width = std.math.cast(u16, width) orelse 0,
            .height = std.math.cast(u16, height) orelse 0,
        };
    }

    /// Returns the complete capability value after one recognized reply.
    ///
    /// ```zig
    /// const next = capabilities.withObservation(.{ .mouse_pixels = .supported });
    /// ```
    pub fn withObservation(capabilities: HostCapabilities, observation: HostCapabilityObservation) HostCapabilities {
        var next = capabilities;
        switch (observation) {
            .kitty_graphics => |support| next.kitty_graphics = observedSupport(support),
            .kitty_zlib => |support| next.kitty_zlib = observedSupport(support),
            .window_pixels => |size| {
                next.window_width_px = size.width;
                next.window_height_px = size.height;
            },
            .cell_pixels => |size| {
                next.cell_width_px = size.width;
                next.cell_height_px = size.height;
            },
            .mouse_pixels => |support| next.mouse_pixels = observedSupport(support),
        }

        return next;
    }

    /// Returns the complete capability value after unanswered probes expire.
    ///
    /// ```zig
    /// const next = capabilities.withExpiredProbes();
    /// ```
    pub fn withExpiredProbes(capabilities: HostCapabilities) HostCapabilities {
        var next = capabilities;
        if (next.kitty_graphics == .unknown) {
            next.kitty_graphics = .unsupported;
        }
        if (next.kitty_zlib == .unknown) {
            next.kitty_zlib = .unsupported;
        }
        if (next.mouse_pixels == .unknown) {
            next.mouse_pixels = .unsupported;
        }

        return next;
    }
};

pub const HostCapabilitySupport = enum { unsupported, supported };

pub const HostCapabilityObservation = union(enum) {
    kitty_graphics: HostCapabilitySupport,
    kitty_zlib: HostCapabilitySupport,
    window_pixels: PixelSize,
    cell_pixels: PixelSize,
    mouse_pixels: HostCapabilitySupport,
};

fn observedSupport(support: HostCapabilitySupport) kitty.Support {
    return switch (support) {
        .unsupported => .unsupported,
        .supported => .supported,
    };
}

pub const PixelSize = struct {
    width: u32,
    height: u32,
};

pub const HostUpdate = struct {
    capabilities: HostCapabilities,
    size: schema.TerminalSize,
};

pub const HostCapabilitiesChange = struct {
    previous: HostCapabilities,
    current: HostCapabilities,
    host_capabilities_revision: u64,
};

pub const HostResizeCommit = struct {
    previous: schema.TerminalSize,
    current: schema.TerminalSize,
    grid_changed: bool,
    cell_size_changed: bool,
    host_revision: u64,
};

pub const HostCommit = struct {
    capabilities: ?HostCapabilitiesChange,
    resize: ?HostResizeCommit,
};

pub const WorkspaceListCollapse = struct {
    collapsed: bool,
    chrome_revision: u64,
};

pub const WorkspaceListCommit = struct {
    runtime_revision: u64,
    count: usize,
    workspace_list_revision: u64,
};

pub const ProxyStatusCommit = struct {
    previous: bool,
    active: bool,
    proxy_status_revision: u64,
};

pub const SystemMetrics = struct {
    runtime_revision: u64,
    cpu_percent: u8,
    memory_used_decigib: u16,
    battery_percent: ?u8,
};

pub const SystemMetricsCommit = struct {
    runtime_revision: u64,
    system_metrics_revision: u64,
};

pub const NotificationPublication = struct {
    id: notifications.Id,
    notifications_revision: u64,
};

pub const NotificationChange = struct {
    notifications_revision: u64,
};

pub const NotificationActivation = struct {
    target: notifications.Target,
    notifications_revision: u64,
};

pub const AgentStatusChange = struct {
    key: agents.AgentKey,
    pane_index: u16,
    provider: schema.AgentProvider,
    previous: schema.AgentStatus,
    current: schema.AgentStatus,
};

pub const AgentStatusChanges = struct {
    items: [agents.max_agents]AgentStatusChange = undefined,
    count: u8 = 0,

    fn append(changes: *AgentStatusChanges, change: AgentStatusChange) void {
        std.debug.assert(changes.count < changes.items.len);
        changes.items[changes.count] = change;
        changes.count += 1;
    }

    /// Borrows status transitions detected during one atomic reconciliation.
    ///
    /// ```zig
    /// for (commit.status_changes.slice()) |change| alert(change);
    /// ```
    pub fn slice(changes: *const AgentStatusChanges) []const AgentStatusChange {
        return changes.items[0..changes.count];
    }
};

pub const AgentSnapshotCommit = struct {
    runtime_revision: u64,
    count: usize,
    status_changes: AgentStatusChanges,
    agent_revision: u64,
};

pub const LocalAgentNavigation = struct {
    pane_id: schema.PaneId,
    select_tab: ?schema.TabId,
};

pub const AgentHandoff = struct {
    pane_id: schema.PaneId,
    fallback_workspace: ?schema.WorkspaceId,
};

pub const AgentNavigationPlan = union(enum) {
    local: LocalAgentNavigation,
    handoff: AgentHandoff,
};

pub const PanePasteSession = struct {
    pane_id: schema.PaneId,
    bracketed_paste: bool,
};

pub const PaneInputTarget = union(enum) {
    focused,
    pane: schema.PaneId,
    paste_session: PanePasteSession,
};

pub const PaneInputPlan = struct {
    pane_id: schema.PaneId,
    input_modes: schema.frame.InputModes,
};

pub const PaneFrameRecovery = struct {
    pane_id: schema.PaneId,
    known_frame_id: u64,
};

pub const PaneFrameCommit = struct {
    pane_id: schema.PaneId,
    location: schema.TabLocation,
    frame_id: u64,
    graphics_visible: bool,
    snapshot: bool,
    spans: u64,
    cells: u64,
    frame_revision: u64,
};

pub const PaneFrameOutcome = union(enum) {
    detached,
    resync: PaneFrameRecovery,
    applied: PaneFrameCommit,
};

pub const PaneGraphicsFallbackCommit = struct {
    pane_id: schema.PaneId,
    visible: bool,
    pane_graphics_revision: u64,
};

pub const PaneMetadataKind = enum {
    cwd,
    foreground,
};

pub const PaneMetadataCommand = union(PaneMetadataKind) {
    cwd: struct {
        pane_id: schema.PaneId,
        /// Borrowed only for the synchronous transition.
        path: []const u8,
    },
    foreground: struct {
        pane_id: schema.PaneId,
        /// Borrowed only for the synchronous transition.
        name: []const u8,
    },
};

pub const PaneMetadataCommit = struct {
    pane_id: schema.PaneId,
    kind: PaneMetadataKind,
    display_changed: bool,
    pane_metadata_revision: u64,
    pane_foreground_revision: u64,
};

pub const PaneViewportTarget = union(enum) {
    absolute: u32,
    relative: i32,
    bottom,
};

pub const PaneViewportCommand = struct {
    pane_id: schema.PaneId,
    target: PaneViewportTarget,
};

pub const PaneViewportChange = struct {
    pane_id: schema.PaneId,
    offset: u32,
    at_bottom: bool,
    viewport_revision: u64,
};

pub const CopyModeCommand = union(enum) {
    key: keybind.Key,
    vertical: i32,
    leave,
};

pub const CopyModeProjection = struct {
    pane_id: schema.PaneId,
    view: copy_mode.View,
};

const CopyModeFrame = struct {
    pane_id: schema.PaneId,
    previous_offset: u32,
    scroll: schema.frame.Scroll,
};

pub const CopyModePlan = struct {
    expected_revision: u64,
    previous: copy_mode.State,
    next: ?copy_mode.State,
    selection: ?schema.CopySelection = null,
    viewport: ?schema.SetPaneViewport = null,
};

pub const CopyModeCommit = struct {
    active: bool,
    viewport: ?PaneViewportChange,
    copy_revision: u64,
};

pub const RequestPaneSplit = struct {
    axis: layout_mod.Axis,
    area: ui.Rect,
};

pub const PaneSplit = struct {
    target_pane: schema.PaneId,
    location: schema.TabLocation,
    axis: layout_mod.Axis,
    area: ui.Rect,
};

pub const PaneResize = schema.PaneResize;

pub const PaneSplitPlan = struct {
    split: PaneSplit,
    provisional_resize: PaneResize,
    restore_resize: PaneResize,
    new_pane_size: schema.TerminalSize,
};

pub const CommitPaneSplit = struct {
    split: PaneSplit,
    new_pane: schema.PaneId,
};

pub const PaneSplitDisposition = enum {
    active,
    inactive,
    stale,
};

pub const PaneSplitCommit = struct {
    pane_id: schema.PaneId,
    location: schema.TabLocation,
    disposition: PaneSplitDisposition,
    change: Change,
};

pub const RecoverPaneSplit = struct {
    split: PaneSplit,
    area: ui.Rect,
};

pub const PaneSplitRecovery = union(enum) {
    resize: PaneResize,
    not_required,
    stale,
};

pub const PaneClosure = struct {
    pane_id: schema.PaneId,
    location: schema.TabLocation,
};

pub const PaneRetirement = struct {
    pane_id: schema.PaneId,
    location: schema.TabLocation,
    active: bool,
    tab_empty: bool,
};

pub const PaneExit = union(enum) {
    retired: PaneRetirement,
    stale: schema.PaneId,
};

pub const RemoveTab = struct {
    location: schema.TabLocation,
    workspace_removed: bool,
};

pub const RemovedPanes = struct {
    items: [schema.max_panes_per_tab]schema.PaneId = undefined,
    count: u8 = 0,

    fn append(panes: *RemovedPanes, pane_id: schema.PaneId) void {
        std.debug.assert(panes.count < panes.items.len);
        panes.items[panes.count] = pane_id;
        panes.count += 1;
    }

    /// Returns pane identities retired by a canonical model transition.
    ///
    /// ```zig
    /// for (removal.panes.slice()) |pane_id| release(pane_id);
    /// ```
    pub fn slice(panes: *const RemovedPanes) []const schema.PaneId {
        return panes.items[0..panes.count];
    }
};

pub const TabRemoval = struct {
    removed: schema.TabLocation,
    panes: RemovedPanes,
    was_active: bool,
    active: ?schema.TabLocation,
    workspace_removed: bool,
};

pub const TabReconciliation = struct {
    location: schema.TabLocation,
    removed_panes: RemovedPanes = .{},
    active: bool,
    panes_changed: bool,
};

pub const WorkspaceTabInput = tabs_mod.WorkspaceTabInput;
pub const WorkspaceSnapshot = tabs_mod.WorkspaceSnapshotInput;
pub const TabSnapshot = tabs_mod.PaneSnapshot;

pub const RemovedWorkspaceTabs = struct {
    items: [schema.max_tabs_per_workspace]schema.TabLocation = undefined,
    count: u8 = 0,

    fn append(tabs: *RemovedWorkspaceTabs, location: schema.TabLocation) void {
        std.debug.assert(tabs.count < tabs.items.len);
        tabs.items[tabs.count] = location;
        tabs.count += 1;
    }

    /// Returns the tab identities absent from the canonical snapshot.
    ///
    /// ```zig
    /// for (reconciliation.removed_tabs.slice()) |location| ignore(location);
    /// ```
    pub fn slice(tabs: *const RemovedWorkspaceTabs) []const schema.TabLocation {
        return tabs.items[0..tabs.count];
    }
};

pub const RemovedWorkspacePanes = struct {
    pub const capacity = schema.max_tabs_per_workspace * schema.max_panes_per_tab;

    items: [capacity]schema.PaneId = undefined,
    count: u16 = 0,

    fn append(panes: *RemovedWorkspacePanes, pane_id: schema.PaneId) void {
        std.debug.assert(panes.count < panes.items.len);
        panes.items[panes.count] = pane_id;
        panes.count += 1;
    }

    /// Returns pane identities whose tab disappeared during reconciliation.
    ///
    /// ```zig
    /// for (reconciliation.removed_panes.slice()) |pane_id| release(pane_id);
    /// ```
    pub fn slice(panes: *const RemovedWorkspacePanes) []const schema.PaneId {
        return panes.items[0..panes.count];
    }
};

pub const WorkspaceReconciliation = struct {
    previous_active: schema.TabLocation,
    active: schema.TabLocation,
    removed_tabs: RemovedWorkspaceTabs = .{},
    removed_panes: RemovedWorkspacePanes = .{},
    workspace_changed: bool = false,
    tabs_changed: bool = false,
    active_tab_changed: bool = false,
};

pub const Model = struct {
    workspace: tabs_mod.Model,
    name_prompt: name_prompt.State = .{},
    workspace_revision: u64 = 0,
    configuration_generation: u64 = 0,
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
    sidebar_animation_frame: u8 = 0,
    sidebar_animation_revision: u64 = 0,
    proxy_tls_active: bool = false,
    proxy_status_revision: u64 = 0,
    system_metrics: ?SystemMetrics = null,
    system_metrics_revision: u64 = 0,
    notification_center: notifications.Center = .{},
    notifications_revision: u64 = 0,
    tabs_revision: u64 = 0,
    active_tab_revision: u64 = 0,
    panes_revision: u64 = 0,
    sidebar_visible: bool = true,
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
            .host_size = initial.host_size,
            .host_capabilities = initial.host_capabilities,
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

        model.configuration_generation = input.generation;
        model.configuration_revision +%= 1;

        return .{
            .generation = model.configuration_generation,
            .configuration_revision = model.configuration_revision,
            .sidebar = sidebar,
            .pane_gaps_changed = pane_gaps_changed,
            .panes_revision = model.panes_revision,
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

    /// Commits an explicit sidebar preference. Repeated values preserve the
    /// chrome revision and produce no projection work.
    ///
    /// ```zig
    /// const change = model.setSidebarVisible(false) orelse return;
    /// ```
    pub fn setSidebarVisible(model: *Model, visible: bool) ?SidebarVisibility {
        if (model.sidebar_visible == visible) {
            return null;
        }

        model.sidebar_visible = visible;
        model.chrome_revision +%= 1;

        return .{
            .visible = visible,
            .chrome_revision = model.chrome_revision,
        };
    }

    /// Toggles the sidebar preference and advances only the chrome revision.
    ///
    /// ```zig
    /// const change = model.toggleSidebar();
    /// ```
    pub fn toggleSidebar(model: *Model) SidebarVisibility {
        return model.setSidebarVisible(!model.sidebar_visible).?;
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
        model.proxy_tls_active = active;
        model.proxy_status_revision +%= 1;

        return .{
            .previous = previous,
            .active = active,
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

        const replaced = try model.agent_snapshot.replace(input);
        std.debug.assert(replaced);
        model.agent_revision +%= 1;

        return .{
            .runtime_revision = model.agent_snapshot.revision,
            .count = model.agent_snapshot.count,
            .status_changes = status_changes,
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

    /// Reports whether one exact pane generation is current.
    ///
    /// ```zig
    /// if (!model.knowsAgent(key)) discardNotification();
    /// ```
    pub fn knowsAgent(model: *const Model, key: agents.AgentKey) bool {
        return model.agent_snapshot.find(key) != null;
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
            .claude, .codex => return key,
            .unknown => return null,
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
    /// and copy mode own normal pane input exclusively, while a captured paste
    /// keeps its exact owner until the terminal sends its closing boundary.
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
        };
        const tab = model.workspace.tabForPane(pane_id) orelse return null;
        const kind = std.meta.activeTag(command);
        const change = switch (command) {
            .cwd => |cwd| try tab.model.setPaneCwd(cwd.pane_id, cwd.path),
            .foreground => |foreground| tab.model.setPaneForeground(foreground.pane_id, foreground.name),
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
    /// try model.arriveWorkspace(arrival);
    /// ```
    pub fn arriveWorkspace(model: *Model, arrival: WorkspaceArrival) !void {
        if (model.workspace.count != 0 or model.workspace.workspace != null) {
            return error.ModelNotEmpty;
        }

        try model.workspace.bootstrap(arrival.pane_id, arrival.location, arrival.size);
        if (arrival.saved_layout) |saved| {
            std.debug.assert(model.workspace.restoreLayoutOnNextSnapshot(arrival.location, saved));
        }

        model.workspace_revision +%= 1;
        model.tabs_revision +%= 1;
        model.active_tab_revision +%= 1;
        model.panes_revision +%= 1;
        releaseInvalidCopyMode(model);
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
            .pane_id = arrival.pane_id,
            .location = arrival.location,
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

    /// Changes focus inside the active tab and reports the committed identity.
    /// Repeated, missing and directionless targets leave every version intact.
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
        const stale: PaneSplitCommit = .{
            .pane_id = command.new_pane,
            .location = command.split.location,
            .disposition = .stale,
            .change = .unchanged,
        };
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

            return .{
                .pane_id = command.new_pane,
                .location = command.split.location,
                .disposition = if (active) .active else .inactive,
                .change = .unchanged,
            };
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

        return .{
            .pane_id = command.new_pane,
            .location = command.split.location,
            .disposition = if (active) .active else .inactive,
            .change = if (active) .changed else .unchanged,
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
        const tab = model.workspace.tabForPane(pane_id) orelse return .{ .stale = pane_id };
        const pane = tab.model.find(pane_id) orelse return .{ .stale = pane_id };
        if (!std.meta.eql(pane.location, tab.location)) {
            return .{ .stale = pane_id };
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
        const previous = (model.workspace.activeConst() orelse return error.NoActiveTab).location;

        _ = try model.workspace.addCreated(command.created, command.size);
        model.tabs_revision +%= 1;
        model.active_tab_revision +%= 1;
        releaseInvalidCopyMode(model);

        return .{
            .previous = previous,
            .created = command.created.location,
        };
    }

    /// Removes a runtime-confirmed tab after validating workspace closure.
    /// Missing tabs return null so lifecycle adapters can remain idempotent.
    ///
    /// ```zig
    /// const removal = try model.removeTab(command) orelse return;
    /// ```
    pub fn removeTab(model: *Model, command: RemoveTab) !?TabRemoval {
        const workspace = model.workspace.workspace orelse return null;
        if (!std.meta.eql(workspace, command.location.workspace)) {
            return error.UnexpectedWorkspace;
        }

        const closing = model.workspace.find(command.location.tab_id) orelse return null;
        if (!std.meta.eql(closing.location, command.location)) {
            return error.UnexpectedTab;
        }

        const workspace_removed = model.workspace.count == 1;
        if (workspace_removed != command.workspace_removed) {
            return error.UnexpectedWorkspaceRemoval;
        }

        const was_active = model.workspace.active_index ==
            model.workspace.indexOf(command.location.tab_id).?;
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

        return .{
            .removed = command.location,
            .panes = panes,
            .was_active = was_active,
            .active = active,
            .workspace_removed = workspace_removed,
        };
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

        const selection: TabSelection = .{
            .previous = previous.location,
            .selected = model.workspace.activeConst().?.location,
        };
        model.active_tab_revision +%= 1;
        releaseInvalidCopyMode(model);

        return selection;
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

const TestingPaneFrame = struct {
    pane_id: schema.PaneId,
    frame_id: u64 = 1,
    base_frame_id: u64 = 0,
    cols: u16 = 2,
    rows: u16 = 2,
    cursor: schema.frame.Cursor = .{},
    input_modes: schema.frame.InputModes = .{},
    scroll: schema.frame.Scroll = .{ .total_rows = 2, .offset = 0 },
    cells: ?[]const ui.Cell = null,
};

fn testingPaneFrame(buffer: []u8, input: TestingPaneFrame) !schema.frame.FrameView {
    var spans: [1]schema.frame.Span = undefined;
    const encoded_spans: []const schema.frame.Span = if (input.cells) |cells| block: {
        spans[0] = .{ .start = 0, .cells = cells };
        break :block &spans;
    } else &.{};
    const encoded = try schema.encodePaneFrame(buffer, .{
        .pane_id = input.pane_id,
        .frame_id = input.frame_id,
        .base_frame_id = input.base_frame_id,
        .cols = input.cols,
        .rows = input.rows,
        .cursor = input.cursor,
        .input_modes = input.input_modes,
        .scroll = input.scroll,
        .spans = encoded_spans,
    });

    return (try schema.decodeServer(encoded)).pane_frame;
}

test "pane input planning resolves one attached active target without mutation" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 20, .rows = 5 });
    const pane = model.workspace.findPane(pane_id).?;
    pane.input_modes = .{ .cursor_keys = true, .bracketed_paste = true };
    const inactive_pane: schema.PaneId = @enumFromInt(2);
    _ = try model.workspace.addCreated(.{
        .location = .{
            .workspace = location.workspace,
            .tab_id = @enumFromInt(2),
        },
        .position = 1,
        .label = "inactive",
        .root_pane_id = inactive_pane,
    }, .{ .cols = 20, .rows = 5 });
    model.workspace.findPane(inactive_pane).?.attached = true;
    try std.testing.expect(model.workspace.select(location.tab_id));
    const version = model.version();
    const expected: PaneInputPlan = .{
        .pane_id = pane_id,
        .input_modes = pane.input_modes,
    };

    try std.testing.expectEqualDeep(expected, model.planPaneInput(.focused).?);
    try std.testing.expectEqualDeep(expected, model.planPaneInput(.{ .pane = pane_id }).?);
    try std.testing.expect(model.planPaneInput(.{ .pane = inactive_pane }) == null);
    try std.testing.expect(model.planPaneInput(.{ .pane = @enumFromInt(9) }) == null);
    try std.testing.expectEqualDeep(version, model.version());

    pane.attached = false;
    try std.testing.expect(model.planPaneInput(.focused) == null);
    try std.testing.expectEqualDeep(version, model.version());
}

test "pane input planning yields ownership to prompts and copy mode" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 20, .rows = 5 });

    model.name_prompt.begin(.create_workspace);
    const prompt_version = model.version();
    try std.testing.expect(model.planPaneInput(.focused) == null);
    try std.testing.expectEqualDeep(prompt_version, model.version());

    try std.testing.expect(model.name_prompt.apply(.cancel) == .cancelled);
    try std.testing.expect(model.enterCopyMode());
    const copy_version = model.version();
    try std.testing.expect(model.planPaneInput(.{ .pane = pane_id }) == null);
    try std.testing.expectEqualDeep(copy_version, model.version());
}

test "reported pane focus derives protocol edges outside presentation versions" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const first: schema.PaneId = @enumFromInt(1);
    const second: schema.PaneId = @enumFromInt(2);
    try model.workspace.bootstrap(first, location, .{ .cols = 20, .rows = 5 });
    const version = model.version();

    const disabled = model.syncReportedPaneFocus().?;

    try std.testing.expectEqualDeep(ReportedPaneFocus{
        .pane_id = first,
        .focus_events = false,
    }, disabled.current.?);
    try std.testing.expect(disabled.previous == null);
    try std.testing.expect(disabled.focus_out == null);
    try std.testing.expect(disabled.focus_in == null);
    try std.testing.expect(model.syncReportedPaneFocus() == null);
    try std.testing.expectEqualDeep(version, model.version());

    model.workspace.findPane(first).?.input_modes.focus_events = true;
    const enabled = model.syncReportedPaneFocus().?;
    try std.testing.expectEqual(first, enabled.focus_in.?);
    try std.testing.expect(enabled.focus_out == null);

    try model.workspace.active().?.model.split(first, second, location, .horizontal, .{ .w = 20, .h = 5 });
    model.workspace.findPane(second).?.input_modes.focus_events = true;
    const moved = model.syncReportedPaneFocus().?;

    try std.testing.expectEqual(first, moved.focus_out.?);
    try std.testing.expectEqual(second, moved.focus_in.?);
    try std.testing.expectEqualDeep(ReportedPaneFocus{
        .pane_id = second,
        .focus_events = true,
    }, model.reportedPaneFocus().?);
    try std.testing.expectEqualDeep(version, model.version());

    model.workspace.findPane(second).?.input_modes.focus_events = false;
    const opted_out = model.syncReportedPaneFocus().?;
    try std.testing.expect(opted_out.focus_out == null);
    try std.testing.expect(opted_out.focus_in == null);
    try std.testing.expect(!model.reportedPaneFocus().?.focus_events);
    try std.testing.expectEqualDeep(version, model.version());
}

test "reported pane focus distinguishes intentional clear from stale retirement" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 20, .rows = 5 });
    const pane = model.workspace.findPane(pane_id).?;
    pane.input_modes.focus_events = true;
    _ = model.syncReportedPaneFocus().?;
    const version = model.version();

    pane.attached = false;
    const clear = model.clearReportedPaneFocus().?;
    try std.testing.expect(clear.focus_out == null);
    try std.testing.expect(model.reportedPaneFocus() == null);
    try std.testing.expect(model.clearReportedPaneFocus() == null);

    _ = model.syncReportedPaneFocus().?;
    try std.testing.expect(!model.releaseReportedPaneFocus(@enumFromInt(9)));
    try std.testing.expect(model.releaseReportedPaneFocus(pane_id));
    try std.testing.expect(!model.releaseReportedPaneFocus(pane_id));

    _ = model.syncReportedPaneFocus().?;
    try std.testing.expect(model.forgetReportedPaneFocus());
    try std.testing.expect(!model.forgetReportedPaneFocus());
    try std.testing.expectEqualDeep(version, model.version());
}

test "pane paste captures one exact target and framing mode outside presentation versions" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 20, .rows = 5 });
    const pane = model.workspace.findPane(pane_id).?;
    pane.input_modes.bracketed_paste = true;
    const version = model.version();

    const session = model.beginPanePaste().?;

    try std.testing.expectEqualDeep(PanePasteSession{
        .pane_id = pane_id,
        .bracketed_paste = true,
    }, session);
    try std.testing.expectEqualDeep(session, model.panePasteSession().?);
    try std.testing.expect(model.panePasteActive());
    try std.testing.expect(model.beginPanePaste() == null);
    try std.testing.expectEqualDeep(version, model.version());

    const other_location: schema.TabLocation = .{
        .workspace = location.workspace,
        .tab_id = @enumFromInt(2),
    };
    _ = try model.workspace.addCreated(.{
        .location = other_location,
        .position = 1,
        .label = "other",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expectEqualDeep(other_location, model.workspace.activeConst().?.location);

    pane.input_modes.bracketed_paste = false;
    model.name_prompt.begin(.create_workspace);
    try std.testing.expect(model.planPaneInput(.focused) == null);
    const captured = model.planPaneInput(.{ .paste_session = session }).?;
    try std.testing.expectEqual(pane_id, captured.pane_id);
    try std.testing.expect(!captured.input_modes.bracketed_paste);

    const wrong = PanePasteSession{ .pane_id = pane_id, .bracketed_paste = false };
    try std.testing.expect(!model.finishPanePaste(wrong));
    try std.testing.expect(!model.releasePanePaste(@enumFromInt(9)));
    try std.testing.expect(model.finishPanePaste(session));
    try std.testing.expect(!model.panePasteActive());
}

test "pane paste release and copy mode keep one input owner" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 20, .rows = 5 });

    _ = model.beginPanePaste().?;
    try std.testing.expect(!model.enterCopyMode());
    try std.testing.expect(model.releasePanePaste(pane_id));
    try std.testing.expect(!model.releasePanePaste(pane_id));

    try std.testing.expect(model.enterCopyMode());
    try std.testing.expect(model.beginPanePaste() == null);
}

test "pane frame application commits screen copy state and one frame revision" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 2, .rows = 2 });
    const pane = model.workspace.findPane(pane_id).?;
    pane.scroll = .{ .total_rows = 4, .offset = 2 };
    pane.cursor = .{ .visible = true, .x = 0, .y = 1 };
    try std.testing.expect(model.enterCopyMode());
    const cells = [_]ui.Cell{
        .{ .bytes = [_]u8{'x'} ++ [_]u8{0} ** (ui.Cell.max_bytes - 1) },
        .{},
        .{},
        .{},
    };
    var encoded: [512]u8 = undefined;

    const outcome = try model.applyPaneFrame(try testingPaneFrame(&encoded, .{
        .pane_id = pane_id,
        .frame_id = 7,
        .cursor = .{ .visible = true, .x = 1, .y = 1 },
        .input_modes = .{ .cursor_keys = true },
        .scroll = .{ .total_rows = 3, .offset = 1 },
        .cells = &cells,
    }));
    const commit = outcome.applied;

    try std.testing.expectEqual(pane_id, commit.pane_id);
    try std.testing.expectEqualDeep(location, commit.location);
    try std.testing.expectEqual(@as(u64, 7), commit.frame_id);
    try std.testing.expect(commit.graphics_visible);
    try std.testing.expect(commit.snapshot);
    try std.testing.expectEqual(@as(u64, 1), commit.spans);
    try std.testing.expectEqual(@as(u64, 4), commit.cells);
    try std.testing.expectEqual(@as(u64, 1), commit.frame_revision);
    try std.testing.expectEqualStrings("x", pane.buffer.cells[0].text());
    try std.testing.expect(pane.input_modes.cursor_keys);
    try std.testing.expectEqual(@as(u64, 7), pane.applied_frame_id);
    try std.testing.expectEqual(@as(u64, 7), pane.pending_frame_id);
    try std.testing.expectEqual(@as(u32, 2), model.copyModeProjection().?.view.cursor.y);
    try std.testing.expectEqualDeep(Version{ .copy = 2, .frame = 1 }, model.version());
}

test "pane frame application separates stale detach recovery and invalid input" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 2, .rows = 2 });
    const pane = model.workspace.findPane(pane_id).?;
    pane.applied_frame_id = 3;
    var encoded: [512]u8 = undefined;

    const recovery = try model.applyPaneFrame(try testingPaneFrame(&encoded, .{
        .pane_id = pane_id,
        .frame_id = 4,
        .base_frame_id = 2,
    }));

    try std.testing.expectEqualDeep(PaneFrameRecovery{
        .pane_id = pane_id,
        .known_frame_id = 3,
    }, recovery.resync);
    try std.testing.expectEqualDeep(Version{}, model.version());
    try std.testing.expectEqual(@as(u64, 0), pane.pending_frame_id);

    pane.attached = false;
    const detached = try model.applyPaneFrame(try testingPaneFrame(&encoded, .{
        .pane_id = pane_id,
        .frame_id = 5,
        .cells = &[_]ui.Cell{ .{}, .{}, .{}, .{} },
    }));
    try std.testing.expect(detached == .detached);
    try std.testing.expectEqualDeep(Version{}, model.version());

    try std.testing.expectError(error.UnexpectedPane, model.applyPaneFrame(try testingPaneFrame(&encoded, .{
        .pane_id = @enumFromInt(9),
        .cells = &[_]ui.Cell{ .{}, .{}, .{}, .{} },
    })));
    try std.testing.expectEqualDeep(Version{}, model.version());
}

test "pane frame apply failure does not publish a frame revision" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 2, .rows = 2 });
    const pane = model.workspace.findPane(pane_id).?;
    pane.applied_frame_id = 3;
    var encoded: [256]u8 = undefined;

    try std.testing.expectError(error.PatchSizeMismatch, model.applyPaneFrame(try testingPaneFrame(&encoded, .{
        .pane_id = pane_id,
        .frame_id = 4,
        .base_frame_id = 3,
        .cols = 3,
    })));

    try std.testing.expectEqual(@as(u64, 3), pane.applied_frame_id);
    try std.testing.expectEqual(@as(u64, 0), pane.pending_frame_id);
    try std.testing.expectEqualDeep(Version{}, model.version());
}

test "pane graphics fallback versions only semantic changes" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 2, .rows = 2 });
    const tab = model.workspace.active().?;
    tab.model.composition_invalidated = false;

    const shown = model.setPaneGraphicsFallback(pane_id, true).?;

    try std.testing.expect(shown.visible);
    try std.testing.expectEqual(@as(u64, 1), shown.pane_graphics_revision);
    try std.testing.expect(tab.model.find(pane_id).?.graphics_placeholder);
    try std.testing.expect(tab.model.composition_invalidated);
    try std.testing.expectEqualDeep(Version{ .pane_graphics = 1 }, model.version());

    tab.model.composition_invalidated = false;
    try std.testing.expect(model.setPaneGraphicsFallback(pane_id, true) == null);
    try std.testing.expect(model.setPaneGraphicsFallback(@enumFromInt(9), true) == null);
    try std.testing.expect(!tab.model.composition_invalidated);
    try std.testing.expectEqualDeep(Version{ .pane_graphics = 1 }, model.version());

    const hidden = model.setPaneGraphicsFallback(pane_id, false).?;

    try std.testing.expect(!hidden.visible);
    try std.testing.expectEqual(@as(u64, 2), hidden.pane_graphics_revision);
    try std.testing.expect(!tab.model.find(pane_id).?.graphics_placeholder);
    try std.testing.expectEqualDeep(Version{ .pane_graphics = 2 }, model.version());
}

test "pane cwd metadata stores exact paths and versions only display changes" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 2, .rows = 2 });
    const tab = model.workspace.active().?;
    tab.model.composition_invalidated = false;

    const visible = (try model.updatePaneMetadata(.{ .cwd = .{
        .pane_id = pane_id,
        .path = "/work/telar",
    } })).?;

    try std.testing.expectEqual(PaneMetadataKind.cwd, visible.kind);
    try std.testing.expect(visible.display_changed);
    try std.testing.expectEqual(@as(u64, 1), visible.pane_metadata_revision);
    try std.testing.expectEqual(@as(u64, 0), visible.pane_foreground_revision);
    try std.testing.expectEqualStrings("/work/telar", tab.model.find(pane_id).?.cwdSlice());
    try std.testing.expectEqualDeep(Version{ .pane_metadata = 1 }, model.version());
    try std.testing.expect(!tab.model.composition_invalidated);

    const stored = (try model.updatePaneMetadata(.{ .cwd = .{
        .pane_id = pane_id,
        .path = "/other/telar",
    } })).?;

    try std.testing.expect(!stored.display_changed);
    try std.testing.expectEqual(@as(u64, 1), stored.pane_metadata_revision);
    try std.testing.expectEqualStrings("/other/telar", tab.model.find(pane_id).?.cwdSlice());
    try std.testing.expectEqualDeep(Version{ .pane_metadata = 1 }, model.version());
    try std.testing.expect((try model.updatePaneMetadata(.{ .cwd = .{
        .pane_id = pane_id,
        .path = "/other/telar",
    } })) == null);
    try std.testing.expect((try model.updatePaneMetadata(.{ .cwd = .{
        .pane_id = @enumFromInt(9),
        .path = "/missing",
    } })) == null);

    _ = (try model.updatePaneMetadata(.{ .cwd = .{
        .pane_id = pane_id,
        .path = "/other/api",
    } })).?;
    try std.testing.expectEqualDeep(Version{ .pane_metadata = 2 }, model.version());
}

test "pane foreground metadata versions display and composition independently" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 2, .rows = 2 });
    const tab = model.workspace.active().?;
    tab.model.composition_invalidated = false;

    const first = (try model.updatePaneMetadata(.{ .foreground = .{
        .pane_id = pane_id,
        .name = "zsh",
    } })).?;

    try std.testing.expectEqual(PaneMetadataKind.foreground, first.kind);
    try std.testing.expect(first.display_changed);
    try std.testing.expectEqual(@as(u64, 1), first.pane_metadata_revision);
    try std.testing.expectEqual(@as(u64, 1), first.pane_foreground_revision);
    try std.testing.expectEqualStrings("zsh", tab.model.find(pane_id).?.foregroundName());
    try std.testing.expectEqualDeep(Version{
        .pane_metadata = 1,
        .pane_foreground = 1,
    }, model.version());
    try std.testing.expect(!tab.model.composition_invalidated);
    try std.testing.expect((try model.updatePaneMetadata(.{ .foreground = .{
        .pane_id = pane_id,
        .name = "zsh",
    } })) == null);
    try std.testing.expect((try model.updatePaneMetadata(.{ .foreground = .{
        .pane_id = @enumFromInt(9),
        .name = "bash",
    } })) == null);

    _ = (try model.updatePaneMetadata(.{ .foreground = .{
        .pane_id = pane_id,
        .name = "bash",
    } })).?;
    try std.testing.expectEqualDeep(Version{
        .pane_metadata = 2,
        .pane_foreground = 2,
    }, model.version());
}

test "pane cwd allocation failure preserves metadata and revisions" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 2, .rows = 2 });
    _ = (try model.updatePaneMetadata(.{ .cwd = .{
        .pane_id = pane_id,
        .path = "/work/telar",
    } })).?;
    const pane = model.workspace.findPane(pane_id).?;
    const version = model.version();
    const original_gpa = pane.gpa;
    pane.gpa = std.testing.failing_allocator;
    const result = model.updatePaneMetadata(.{ .cwd = .{
        .pane_id = pane_id,
        .path = "/work/api",
    } });
    pane.gpa = original_gpa;

    try std.testing.expectError(error.OutOfMemory, result);
    try std.testing.expectEqualStrings("/work/telar", pane.cwdSlice());
    try std.testing.expectEqualDeep(version, model.version());
}

test "pane viewport intents are bounded versioned and reserved by copy mode" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 20, .rows = 5 });
    const pane = model.workspace.findPane(pane_id).?;
    pane.scroll = .{ .total_rows = 20, .offset = 10 };
    pane.cursor = .{ .visible = true, .x = 2, .y = 4 };

    const top = model.setPaneViewport(.{
        .pane_id = pane_id,
        .target = .{ .relative = -100 },
    }).?;

    try std.testing.expectEqual(@as(u32, 0), top.offset);
    try std.testing.expect(!top.at_bottom);
    try std.testing.expectEqual(@as(u64, 1), top.viewport_revision);
    try std.testing.expectEqualDeep(Version{ .viewport = 1 }, model.version());
    try std.testing.expect(model.setPaneViewport(.{
        .pane_id = pane_id,
        .target = .{ .absolute = 0 },
    }) == null);

    const bottom = model.setPaneViewport(.{
        .pane_id = pane_id,
        .target = .{ .absolute = std.math.maxInt(u32) },
    }).?;

    try std.testing.expectEqual(@as(u32, 15), bottom.offset);
    try std.testing.expect(bottom.at_bottom);
    try std.testing.expectEqual(@as(u64, 2), bottom.viewport_revision);
    try std.testing.expect(model.setPaneViewport(.{
        .pane_id = pane_id,
        .target = .bottom,
    }) == null);
    try std.testing.expect(model.setPaneViewport(.{
        .pane_id = @enumFromInt(9),
        .target = .bottom,
    }) == null);
    try std.testing.expectEqualDeep(Version{ .viewport = 2 }, model.version());

    pane.scroll.offset = 10;
    try std.testing.expect(model.enterCopyMode());
    const copy_version = model.version();
    try std.testing.expect(model.setPaneViewport(.{
        .pane_id = pane_id,
        .target = .bottom,
    }) == null);
    try std.testing.expectEqualDeep(copy_version, model.version());

    const copy_commit = model.commitCopyMode(model.planCopyMode(.{
        .key = try keybind.parseKey("g"),
    }).?).?;

    try std.testing.expectEqual(@as(u32, 0), copy_commit.viewport.?.offset);
    try std.testing.expectEqual(@as(u64, 3), copy_commit.viewport.?.viewport_revision);
    try std.testing.expectEqual(copy_version.copy + 1, model.version().copy);
    try std.testing.expectEqual(copy_version.viewport + 1, model.version().viewport);
}

test "copy mode entry owns one independent model revision" {
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
    pane.cursor = .{ .visible = true, .x = 4, .y = 2 };

    try std.testing.expect(model.copyModeTarget() == null);
    try std.testing.expect(model.enterCopyMode());

    try std.testing.expect(model.copyModeActive());
    try std.testing.expectEqual(pane_id, model.copyModeTarget().?);
    try std.testing.expectEqualDeep(CopyModeProjection{
        .pane_id = pane_id,
        .view = .{
            .cursor = .{ .x = 4, .y = 12 },
            .anchor = null,
            .linewise = false,
        },
    }, model.copyModeProjection().?);
    try std.testing.expectEqualDeep(Version{ .copy = 1 }, model.version());
    try std.testing.expect(!model.enterCopyMode());
    try std.testing.expectEqualDeep(Version{ .copy = 1 }, model.version());

    const leave = model.planCopyMode(.leave).?;
    _ = model.commitCopyMode(leave).?;
    model.name_prompt.begin(.create_workspace);
    const copy_revision = model.version().copy;

    try std.testing.expect(!model.enterCopyMode());
    try std.testing.expectEqual(copy_revision, model.version().copy);
}

test "copy mode plans reject no-ops and stale commits" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.workspace.bootstrap(@enumFromInt(1), location, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model.enterCopyMode());
    const version = model.version();

    try std.testing.expect(model.planCopyMode(.{ .key = try keybind.parseKey("left") }) == null);
    try std.testing.expect(model.planCopyMode(.{ .key = try keybind.parseKey("z") }) == null);
    try std.testing.expectEqualDeep(version, model.version());

    const first = model.planCopyMode(.{ .key = try keybind.parseKey("right") }).?;
    const stale = model.planCopyMode(.{ .key = try keybind.parseKey("right") }).?;
    const commit = model.commitCopyMode(first).?;

    try std.testing.expect(commit.active);
    try std.testing.expectEqual(version.copy + 1, commit.copy_revision);
    try std.testing.expect(model.commitCopyMode(stale) == null);
    try std.testing.expectEqual(version.copy + 1, model.version().copy);
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

test "an active tab transition releases copy authority" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: schema.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(1) };
    const second: schema.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(2) };
    try model.workspace.bootstrap(@enumFromInt(1), first, .{ .cols = 20, .rows = 5 });
    _ = try model.workspace.addCreated(.{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model.workspace.select(first.tab_id));
    try std.testing.expect(model.enterCopyMode());
    const version = model.version();

    const selection = (try model.selectTab(.{ .tab_id = second.tab_id })).?;

    try std.testing.expectEqualDeep(first, selection.previous);
    try std.testing.expectEqualDeep(second, selection.selected);
    try std.testing.expect(!model.copyModeActive());
    try std.testing.expectEqual(version.active_tab + 1, model.version().active_tab);
    try std.testing.expectEqual(version.copy + 1, model.version().copy);
}

test "workspace creation planning requires the attached focused pane" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    try std.testing.expect(model.planWorkspaceCreation() == null);
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 20, .rows = 5 });

    try std.testing.expectEqual(pane_id, model.planWorkspaceCreation().?);
    model.workspace.findPane(pane_id).?.attached = false;
    try std.testing.expect(model.planWorkspaceCreation() == null);
    try std.testing.expectEqualDeep(Version{}, model.version());
}

test "tab creation planning captures the workspace and attached focused pane" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    try std.testing.expect(model.planTabCreation() == null);
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 20, .rows = 5 });

    try std.testing.expectEqualDeep(TabCreationPlan{
        .workspace = location.workspace,
        .cwd_source = pane_id,
    }, model.planTabCreation().?);
    model.workspace.findPane(pane_id).?.attached = false;
    try std.testing.expect(model.planTabCreation() == null);
    try std.testing.expectEqualDeep(Version{}, model.version());
}

test "workspace departure commits one empty version and captures bounded client state" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const active: schema.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(1) };
    const inactive: schema.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(2) };
    const first: schema.PaneId = @enumFromInt(1);
    const focused: schema.PaneId = @enumFromInt(2);
    const third: schema.PaneId = @enumFromInt(3);
    const area: ui.Rect = .{ .w = 40, .h = 10 };
    try model.workspace.bootstrap(first, active, .{ .cols = 20, .rows = 5 });
    try model.workspace.active().?.model.split(first, focused, active, .horizontal, area);
    _ = try model.workspace.addCreated(.{
        .location = inactive,
        .position = 1,
        .label = "logs",
        .root_pane_id = third,
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model.workspace.select(active.tab_id));

    const departure = model.departWorkspace();

    try std.testing.expectEqualDeep(@as(?schema.WorkspaceLocation, workspace), departure.source);
    try std.testing.expectEqualDeep(active, departure.bookmark.?.location);
    try std.testing.expectEqual(focused, departure.bookmark.?.pane_id);
    try std.testing.expectEqual(focused, departure.bookmark.?.tab_layout.focused().?);
    try std.testing.expectEqualSlices(schema.PaneId, &.{ first, focused, third }, departure.panes.slice());
    try std.testing.expect(model.workspace.workspace == null);
    try std.testing.expectEqual(@as(usize, 0), model.workspace.count);
    try std.testing.expectEqualDeep(Version{
        .workspace = 1,
        .tabs = 1,
        .active_tab = 1,
        .panes = 1,
    }, model.version());

    const version = model.version();
    const repeated = model.departWorkspace();

    try std.testing.expect(repeated.source == null);
    try std.testing.expect(repeated.bookmark == null);
    try std.testing.expectEqual(@as(usize, 0), repeated.panes.slice().len);
    try std.testing.expectEqualDeep(version, model.version());
}

test "workspace arrival commits atomically and stages the saved layout" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = @enumFromInt(4),
    };
    const left: schema.PaneId = @enumFromInt(10);
    const focused: schema.PaneId = @enumFromInt(11);
    const area: ui.Rect = .{ .w = 60, .h = 12 };
    var saved: layout_mod.Layout = .{};
    try saved.addRoot(left);
    try saved.split(left, focused, .horizontal);
    var expected: layout_mod.Snapshot = .{};
    saved.snapshot(area, &expected);

    try model.arriveWorkspace(.{
        .pane_id = focused,
        .location = location,
        .size = .{ .cols = 30, .rows = 8 },
        .saved_layout = saved,
    });

    try std.testing.expectEqualDeep(location, model.activeTabLocation().?);
    try std.testing.expectEqual(focused, model.workspace.activeConst().?.model.layout.focused().?);
    try std.testing.expectEqualDeep(Version{
        .workspace = 1,
        .tabs = 1,
        .active_tab = 1,
        .panes = 1,
    }, model.version());

    const snapshot: TabSnapshot = .{
        .location = location,
        .panes = &.{ left, focused },
    };
    _ = try model.reconcileTab(snapshot, area);
    var actual: layout_mod.Snapshot = .{};
    model.workspace.activeConst().?.model.layout.snapshot(area, &actual);

    try std.testing.expectEqual(focused, model.workspace.activeConst().?.model.layout.focused().?);
    for ([_]schema.PaneId{ left, focused }) |pane_id| {
        try std.testing.expectEqual(expected.find(pane_id).?.outer, actual.find(pane_id).?.outer);
    }
}

test "rejected workspace arrival preserves its previous model and version" {
    var empty = Model.init(std.testing.allocator, true);
    defer empty.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = @enumFromInt(4),
    };

    try std.testing.expectError(error.InvalidPaneId, empty.arriveWorkspace(.{
        .pane_id = .invalid,
        .location = location,
        .size = .{ .cols = 30, .rows = 8 },
    }));

    try std.testing.expect(empty.workspace.workspace == null);
    try std.testing.expectEqual(@as(usize, 0), empty.workspace.count);
    try std.testing.expectEqualDeep(Version{}, empty.version());

    var occupied = Model.init(std.testing.allocator, true);
    defer occupied.deinit();
    try occupied.workspace.bootstrap(@enumFromInt(1), location, .{ .cols = 30, .rows = 8 });

    try std.testing.expectError(error.ModelNotEmpty, occupied.arriveWorkspace(.{
        .pane_id = @enumFromInt(2),
        .location = location,
        .size = .{ .cols = 30, .rows = 8 },
    }));

    try std.testing.expectEqual(@as(usize, 1), occupied.workspace.count);
    try std.testing.expect(occupied.workspace.findPane(@enumFromInt(1)) != null);
    try std.testing.expectEqualDeep(Version{}, occupied.version());
}

test "workspace replacement commits the confirmed root and captures retired state" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const previous_workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const previous: schema.TabLocation = .{
        .workspace = previous_workspace,
        .tab_id = @enumFromInt(1),
    };
    const inactive: schema.TabLocation = .{
        .workspace = previous_workspace,
        .tab_id = @enumFromInt(2),
    };
    const replacement: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = @enumFromInt(3),
    };
    const first: schema.PaneId = @enumFromInt(1);
    const focused: schema.PaneId = @enumFromInt(2);
    const inactive_pane: schema.PaneId = @enumFromInt(3);
    const replacement_pane: schema.PaneId = @enumFromInt(4);
    try model.workspace.bootstrap(first, previous, .{ .cols = 20, .rows = 5 });
    try model.workspace.active().?.model.split(first, focused, previous, .horizontal, .{ .w = 40, .h = 10 });
    _ = try model.workspace.addCreated(.{
        .location = inactive,
        .position = 1,
        .label = "logs",
        .root_pane_id = inactive_pane,
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model.workspace.select(previous.tab_id));

    const committed = try model.replaceWorkspace(.{
        .pane_id = replacement_pane,
        .location = replacement,
        .size = .{ .cols = 30, .rows = 8 },
    });

    try std.testing.expectEqualDeep(@as(?schema.WorkspaceLocation, previous_workspace), committed.departure.source);
    try std.testing.expectEqualDeep(previous, committed.departure.bookmark.?.location);
    try std.testing.expectEqual(focused, committed.departure.bookmark.?.pane_id);
    try std.testing.expectEqualSlices(schema.PaneId, &.{ first, focused, inactive_pane }, committed.departure.panes.slice());
    try std.testing.expectEqual(replacement_pane, committed.pane_id);
    try std.testing.expectEqualDeep(replacement, committed.location);
    try std.testing.expectEqualDeep(replacement, model.activeTabLocation().?);
    try std.testing.expectEqual(@as(usize, 1), model.workspace.count);
    try std.testing.expect(model.workspace.findPane(first) == null);
    try std.testing.expect(model.workspace.findPane(replacement_pane) != null);
    try std.testing.expectEqualDeep(Version{
        .workspace = 1,
        .tabs = 1,
        .active_tab = 1,
        .panes = 1,
    }, model.version());
}

test "rejected workspace replacement preserves the occupied projection" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 20, .rows = 5 });

    try std.testing.expectError(error.WorkspaceAlreadyActive, model.replaceWorkspace(.{
        .pane_id = @enumFromInt(2),
        .location = .{ .workspace = location.workspace, .tab_id = @enumFromInt(2) },
        .size = .{ .cols = 30, .rows = 8 },
    }));
    try std.testing.expectError(error.InvalidPaneId, model.replaceWorkspace(.{
        .pane_id = .invalid,
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(2) },
            .tab_id = @enumFromInt(2),
        },
        .size = .{ .cols = 30, .rows = 8 },
    }));

    try std.testing.expectEqualDeep(location, model.activeTabLocation().?);
    try std.testing.expect(model.workspace.findPane(pane_id) != null);
    try std.testing.expectEqualDeep(Version{}, model.version());
}

test "workspace replacement can recover from an already empty source" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = @enumFromInt(2),
    };

    const committed = try model.replaceWorkspace(.{
        .pane_id = @enumFromInt(2),
        .location = location,
        .size = .{ .cols = 30, .rows = 8 },
    });

    try std.testing.expect(committed.departure.source == null);
    try std.testing.expectEqualDeep(location, model.activeTabLocation().?);
    try std.testing.expectEqualDeep(Version{
        .workspace = 1,
        .tabs = 1,
        .active_tab = 1,
        .panes = 1,
    }, model.version());
}

test "workspace reconciliation versions semantic dimensions independently" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const second: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    try model.workspace.bootstrap(@enumFromInt(1), first, .{ .cols = 20, .rows = 5 });
    _ = try model.workspace.addCreated(.{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    const named: WorkspaceSnapshot = .{
        .workspace = workspace,
        .name = "project",
        .tabs = &.{
            .{ .tab_id = first.tab_id, .pane_count = 1, .label = "main" },
            .{ .tab_id = second.tab_id, .pane_count = 1, .label = "logs" },
        },
    };
    const name_change = try model.reconcileWorkspace(named);

    try std.testing.expect(name_change.workspace_changed);
    try std.testing.expect(!name_change.tabs_changed);
    try std.testing.expect(!name_change.active_tab_changed);
    try std.testing.expectEqualDeep(Version{ .workspace = 1 }, model.version());

    const unchanged = try model.reconcileWorkspace(named);

    try std.testing.expect(!unchanged.workspace_changed);
    try std.testing.expect(!unchanged.tabs_changed);
    try std.testing.expect(!unchanged.active_tab_changed);
    try std.testing.expectEqualDeep(Version{ .workspace = 1 }, model.version());

    const reordered: WorkspaceSnapshot = .{
        .workspace = workspace,
        .name = "project",
        .tabs = &.{
            .{ .tab_id = second.tab_id, .pane_count = 1, .label = "server" },
            .{ .tab_id = first.tab_id, .pane_count = 1, .label = "main" },
        },
    };
    const tabs_change = try model.reconcileWorkspace(reordered);

    try std.testing.expect(!tabs_change.workspace_changed);
    try std.testing.expect(tabs_change.tabs_changed);
    try std.testing.expect(!tabs_change.active_tab_changed);
    try std.testing.expectEqualDeep(second, model.activeTabLocation().?);
    try std.testing.expectEqualStrings("server", model.workspace.items[0].?.labelSlice());
    try std.testing.expectEqualDeep(Version{ .workspace = 1, .tabs = 1 }, model.version());

    const removed: WorkspaceSnapshot = .{
        .workspace = workspace,
        .name = "project",
        .tabs = &.{
            .{ .tab_id = first.tab_id, .pane_count = 1, .label = "main" },
        },
    };
    const active_change = try model.reconcileWorkspace(removed);

    try std.testing.expect(!active_change.workspace_changed);
    try std.testing.expect(active_change.tabs_changed);
    try std.testing.expect(active_change.active_tab_changed);
    try std.testing.expectEqualDeep(second, active_change.previous_active);
    try std.testing.expectEqualDeep(first, active_change.active);
    try std.testing.expectEqualSlices(schema.TabLocation, &.{second}, active_change.removed_tabs.slice());
    try std.testing.expectEqualSlices(schema.PaneId, &.{@enumFromInt(2)}, active_change.removed_panes.slice());
    try std.testing.expectEqualDeep(Version{ .workspace = 1, .tabs = 2, .active_tab = 1 }, model.version());
}

test "rejected workspace snapshots preserve state and revisions" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const location: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    try model.workspace.bootstrap(@enumFromInt(1), location, .{ .cols = 20, .rows = 5 });
    const empty: WorkspaceSnapshot = .{
        .workspace = workspace,
        .name = "project",
        .tabs = &.{},
    };

    try std.testing.expectError(error.WorkspaceHasNoTabs, model.reconcileWorkspace(empty));

    const duplicate: WorkspaceSnapshot = .{
        .workspace = workspace,
        .name = "project",
        .tabs = &.{
            .{ .tab_id = location.tab_id, .pane_count = 1, .label = "main" },
            .{ .tab_id = location.tab_id, .pane_count = 1, .label = "copy" },
        },
    };
    try std.testing.expectError(error.DuplicateTab, model.reconcileWorkspace(duplicate));

    var excessive_tabs: [tabs_mod.max_tabs + 1]WorkspaceTabInput = undefined;
    for (&excessive_tabs, 0..) |*tab, index| {
        tab.* = .{
            .tab_id = @enumFromInt(@as(u64, @intCast(index + 1))),
            .pane_count = 1,
            .label = "tab",
        };
    }
    const excessive: WorkspaceSnapshot = .{
        .workspace = workspace,
        .name = "project",
        .tabs = &excessive_tabs,
    };
    try std.testing.expectError(error.TabLimitReached, model.reconcileWorkspace(excessive));

    try std.testing.expectEqualDeep(location, model.activeTabLocation().?);
    try std.testing.expectEqual(@as(usize, 1), model.workspace.count);
    try std.testing.expect(model.workspace.findPane(@enumFromInt(1)) != null);
    try std.testing.expectEqualStrings("", model.workspace.workspaceName());
    try std.testing.expectEqualDeep(Version{}, model.version());
}

test "active tab reconciliation versions pane changes and reports retired panes" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const first: schema.PaneId = @enumFromInt(1);
    const second: schema.PaneId = @enumFromInt(2);
    try model.workspace.bootstrap(first, location, .{ .cols = 20, .rows = 5 });
    const discovered: TabSnapshot = .{
        .location = location,
        .panes = &.{ first, second },
    };

    const addition = try model.reconcileTab(discovered, .{ .w = 40, .h = 10 });

    try std.testing.expect(addition.active);
    try std.testing.expect(addition.panes_changed);
    try std.testing.expectEqual(@as(usize, 0), addition.removed_panes.slice().len);
    try std.testing.expect(model.workspace.findPane(second) != null);
    try std.testing.expectEqualDeep(Version{ .panes = 1 }, model.version());

    const unchanged = try model.reconcileTab(discovered, .{ .w = 40, .h = 10 });

    try std.testing.expect(!unchanged.panes_changed);
    try std.testing.expectEqualDeep(Version{ .panes = 1 }, model.version());

    const removed: TabSnapshot = .{
        .location = location,
        .panes = &.{second},
    };
    const removal = try model.reconcileTab(removed, .{ .w = 40, .h = 10 });

    try std.testing.expect(removal.panes_changed);
    try std.testing.expectEqualSlices(schema.PaneId, &.{first}, removal.removed_panes.slice());
    try std.testing.expect(model.workspace.findPane(first) == null);
    try std.testing.expectEqualDeep(Version{ .panes = 2 }, model.version());
}

test "tab reconciliation rejects excessive pane membership atomically" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const root_pane: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(root_pane, location, .{ .cols = 20, .rows = 5 });
    var pane_ids: [schema.max_panes_per_tab + 1]schema.PaneId = undefined;
    for (&pane_ids, 0..) |*pane_id, index| {
        pane_id.* = @enumFromInt(@as(u64, @intCast(index + 1)));
    }
    const snapshot: TabSnapshot = .{
        .location = location,
        .panes = &pane_ids,
    };

    try std.testing.expectError(error.TooManyPanes, model.reconcileTab(snapshot, .{ .w = 40, .h = 10 }));

    try std.testing.expectEqual(@as(usize, 1), model.workspace.find(location.tab_id).?.model.pane_count);
    try std.testing.expect(model.workspace.findPane(root_pane) != null);
    try std.testing.expectEqualDeep(Version{}, model.version());
}

test "inactive tab reconciliation does not advance the visible pane revision" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const active: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const inactive: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    try model.workspace.bootstrap(@enumFromInt(1), active, .{ .cols = 20, .rows = 5 });
    _ = try model.workspace.addCreated(.{
        .location = inactive,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model.workspace.select(active.tab_id));
    const snapshot: TabSnapshot = .{
        .location = inactive,
        .panes = &.{ @enumFromInt(2), @enumFromInt(3) },
    };

    const reconciliation = try model.reconcileTab(snapshot, .{ .w = 40, .h = 10 });

    try std.testing.expect(!reconciliation.active);
    try std.testing.expect(reconciliation.panes_changed);
    try std.testing.expect(model.workspace.findPane(@enumFromInt(3)) != null);
    try std.testing.expectEqualDeep(Version{}, model.version());
}

test "tab reconciliation rejects pane identities owned by another tab" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const second: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    try model.workspace.bootstrap(@enumFromInt(1), first, .{ .cols = 20, .rows = 5 });
    _ = try model.workspace.addCreated(.{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    const snapshot: TabSnapshot = .{
        .location = first,
        .panes = &.{ @enumFromInt(1), @enumFromInt(2) },
    };

    try std.testing.expectError(error.PaneAlreadyExists, model.reconcileTab(snapshot, .{ .w = 40, .h = 10 }));

    try std.testing.expectEqual(@as(usize, 1), model.workspace.find(first.tab_id).?.model.pane_count);
    try std.testing.expectEqual(@as(usize, 1), model.workspace.find(second.tab_id).?.model.pane_count);
    try std.testing.expectEqualDeep(Version{}, model.version());
}

test "pane attachment confirmation changes only active operational state" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const discovered: schema.PaneId = @enumFromInt(2);
    try model.workspace.bootstrap(@enumFromInt(1), location, .{ .cols = 20, .rows = 5 });
    try model.workspace.active().?.model.addDiscovered(discovered, location, .{ .w = 40, .h = 10 });
    const attachment: PaneAttachment = .{ .pane_id = discovered, .location = location };

    try std.testing.expect(model.needsPaneAttachment(attachment));
    try std.testing.expectEqual(PaneAttachmentConfirmation.confirmed, model.confirmPaneAttachment(attachment));
    try std.testing.expect(!model.needsPaneAttachment(attachment));
    try std.testing.expect(model.workspace.findPane(discovered).?.attached);
    try std.testing.expectEqualDeep(Version{}, model.version());

    try std.testing.expectEqual(PaneAttachmentConfirmation.stale, model.confirmPaneAttachment(attachment));
    try std.testing.expectEqualDeep(Version{}, model.version());
}

test "pane attachment confirmation ignores inactive missing and wrong-location panes" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: schema.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(1) };
    const second: schema.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(2) };
    const discovered: schema.PaneId = @enumFromInt(3);
    try model.workspace.bootstrap(@enumFromInt(1), first, .{ .cols = 20, .rows = 5 });
    try model.workspace.active().?.model.addDiscovered(discovered, first, .{ .w = 40, .h = 10 });
    _ = try model.workspace.addCreated(.{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expectEqualDeep(second, model.activeTabLocation().?);

    const inactive: PaneAttachment = .{ .pane_id = discovered, .location = first };
    try std.testing.expectEqual(PaneAttachmentConfirmation.stale, model.confirmPaneAttachment(inactive));
    try std.testing.expect(!model.needsPaneAttachment(inactive));
    try std.testing.expect(!model.workspace.findPane(discovered).?.attached);

    try std.testing.expect(model.workspace.select(first.tab_id));
    const missing: PaneAttachment = .{ .pane_id = @enumFromInt(9), .location = first };
    const wrong_location: PaneAttachment = .{ .pane_id = discovered, .location = second };
    try std.testing.expectEqual(PaneAttachmentConfirmation.stale, model.confirmPaneAttachment(missing));
    try std.testing.expectEqual(PaneAttachmentConfirmation.stale, model.confirmPaneAttachment(wrong_location));
    try std.testing.expect(!model.needsPaneAttachment(missing));
    try std.testing.expect(!model.needsPaneAttachment(wrong_location));
    try std.testing.expect(!model.workspace.findPane(discovered).?.attached);
    try std.testing.expectEqualDeep(Version{}, model.version());
}

test "tab position commits version semantic changes only" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const second: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    try model.workspace.bootstrap(@enumFromInt(1), first, .{ .cols = 20, .rows = 5 });
    _ = try model.workspace.addCreated(.{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model.workspace.select(first.tab_id));

    try std.testing.expectEqual(Change.changed, try model.applyTabPosition(first, 1));
    try std.testing.expectEqual(@as(u64, 1), model.version().tabs);
    try std.testing.expectEqual(@as(u64, 0), model.version().active_tab);
    try std.testing.expectEqual(first, model.activeTabLocation().?);

    try std.testing.expectEqual(Change.unchanged, try model.applyTabPosition(first, 1));
    try std.testing.expectEqual(@as(u64, 1), model.version().tabs);
}

test "rejected tab positions do not advance the model" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const location: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    try model.workspace.bootstrap(@enumFromInt(1), location, .{ .cols = 20, .rows = 5 });

    const other_workspace: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = location.tab_id,
    };
    try std.testing.expectError(error.UnexpectedWorkspace, model.applyTabPosition(other_workspace, 0));
    try std.testing.expectError(error.TabNotFound, model.applyTabPosition(.{
        .workspace = workspace,
        .tab_id = @enumFromInt(9),
    }, 0));
    try std.testing.expectError(error.InvalidTabPosition, model.applyTabPosition(location, 1));
    try std.testing.expectEqualDeep(Version{}, model.version());
}

test "tab rename advances only the collection revision for a semantic change" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const second: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    try model.workspace.bootstrap(@enumFromInt(1), first, .{ .cols = 20, .rows = 5 });
    _ = try model.workspace.addCreated(.{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model.workspace.select(first.tab_id));

    try std.testing.expectEqual(Change.changed, try model.renameTab(.{
        .location = second,
        .label = "server",
    }));
    try std.testing.expectEqualStrings("server", model.workspace.find(second.tab_id).?.labelSlice());
    try std.testing.expectEqualDeep(first, model.activeTabLocation().?);
    try std.testing.expectEqual(@as(u64, 1), model.version().tabs);
    try std.testing.expectEqual(@as(u64, 0), model.version().active_tab);

    try std.testing.expectEqual(Change.unchanged, try model.renameTab(.{
        .location = second,
        .label = "server",
    }));
    try std.testing.expectEqual(@as(u64, 1), model.version().tabs);
}

test "rejected tab renames preserve labels and revisions" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const location: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    try model.workspace.bootstrap(@enumFromInt(1), location, .{ .cols = 20, .rows = 5 });

    try std.testing.expectError(error.UnexpectedWorkspace, model.renameTab(.{
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(2) },
            .tab_id = location.tab_id,
        },
        .label = "wrong workspace",
    }));
    try std.testing.expectError(error.TabNotFound, model.renameTab(.{
        .location = .{ .workspace = workspace, .tab_id = @enumFromInt(9) },
        .label = "missing",
    }));
    try std.testing.expectError(error.InvalidTabLabel, model.renameTab(.{
        .location = location,
        .label = "",
    }));

    try std.testing.expectEqualStrings("main", model.workspace.activeConst().?.labelSlice());
    try std.testing.expectEqualDeep(Version{}, model.version());
}

test "tab creation advances collection and active identity revisions" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const second: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    try model.workspace.bootstrap(@enumFromInt(1), first, .{ .cols = 20, .rows = 5 });

    const creation = try model.createTab(.{
        .created = .{
            .location = second,
            .position = 0,
            .label = "logs",
            .root_pane_id = @enumFromInt(2),
        },
        .size = .{ .cols = 20, .rows = 5 },
    });

    try std.testing.expectEqualDeep(first, creation.previous);
    try std.testing.expectEqualDeep(second, creation.created);
    try std.testing.expectEqualDeep(second, model.activeTabLocation().?);
    try std.testing.expectEqual(@as(usize, 2), model.workspace.count);
    try std.testing.expectEqual(@as(u64, 1), model.version().tabs);
    try std.testing.expectEqual(@as(u64, 1), model.version().active_tab);
}

test "rejected tab creations preserve state and revisions" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    try model.workspace.bootstrap(@enumFromInt(1), first, .{ .cols = 20, .rows = 5 });
    const size: schema.TerminalSize = .{ .cols = 20, .rows = 5 };

    try std.testing.expectError(error.UnexpectedWorkspace, model.createTab(.{
        .created = .{
            .location = .{
                .workspace = .{ .workspace = @enumFromInt(2) },
                .tab_id = @enumFromInt(2),
            },
            .position = 1,
            .label = "wrong workspace",
            .root_pane_id = @enumFromInt(2),
        },
        .size = size,
    }));
    try std.testing.expectError(error.TabAlreadyExists, model.createTab(.{
        .created = .{
            .location = first,
            .position = 1,
            .label = "duplicate tab",
            .root_pane_id = @enumFromInt(2),
        },
        .size = size,
    }));
    try std.testing.expectError(error.PaneAlreadyExists, model.createTab(.{
        .created = .{
            .location = .{ .workspace = workspace, .tab_id = @enumFromInt(2) },
            .position = 1,
            .label = "duplicate pane",
            .root_pane_id = @enumFromInt(1),
        },
        .size = size,
    }));
    try std.testing.expectError(error.InvalidTabPosition, model.createTab(.{
        .created = .{
            .location = .{ .workspace = workspace, .tab_id = @enumFromInt(2) },
            .position = 2,
            .label = "bad position",
            .root_pane_id = @enumFromInt(2),
        },
        .size = size,
    }));

    try std.testing.expectEqualDeep(first, model.activeTabLocation().?);
    try std.testing.expectEqual(@as(usize, 1), model.workspace.count);
    try std.testing.expectEqualDeep(Version{}, model.version());
}

test "active tab removal advances collection and active identity revisions" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const second: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    try model.workspace.bootstrap(@enumFromInt(1), first, .{ .cols = 20, .rows = 5 });
    _ = try model.workspace.addCreated(.{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model.workspace.select(first.tab_id));

    const removal = (try model.removeTab(.{
        .location = first,
        .workspace_removed = false,
    })).?;

    try std.testing.expectEqualDeep(first, removal.removed);
    try std.testing.expect(removal.was_active);
    try std.testing.expectEqualDeep(second, removal.active.?);
    try std.testing.expectEqualSlices(schema.PaneId, &.{@enumFromInt(1)}, removal.panes.slice());
    try std.testing.expectEqual(@as(u64, 1), model.version().tabs);
    try std.testing.expectEqual(@as(u64, 1), model.version().active_tab);
}

test "inactive tab removal preserves the active identity revision" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const second: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    try model.workspace.bootstrap(@enumFromInt(1), first, .{ .cols = 20, .rows = 5 });
    _ = try model.workspace.addCreated(.{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model.workspace.select(first.tab_id));

    const removal = (try model.removeTab(.{
        .location = second,
        .workspace_removed = false,
    })).?;

    try std.testing.expect(!removal.was_active);
    try std.testing.expectEqualDeep(first, removal.active.?);
    try std.testing.expectEqual(@as(u64, 1), model.version().tabs);
    try std.testing.expectEqual(@as(u64, 0), model.version().active_tab);
}

test "workspace closure is validated before the last tab is removed" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.workspace.bootstrap(@enumFromInt(1), location, .{ .cols = 20, .rows = 5 });

    try std.testing.expectError(error.UnexpectedWorkspaceRemoval, model.removeTab(.{
        .location = location,
        .workspace_removed = false,
    }));
    try std.testing.expectEqual(@as(usize, 1), model.workspace.count);
    try std.testing.expectEqualDeep(Version{}, model.version());

    const removal = (try model.removeTab(.{
        .location = location,
        .workspace_removed = true,
    })).?;

    try std.testing.expect(removal.workspace_removed);
    try std.testing.expect(removal.was_active);
    try std.testing.expect(removal.active == null);
    try std.testing.expectEqual(@as(usize, 0), model.workspace.count);
    try std.testing.expectEqual(@as(u64, 1), model.version().tabs);
    try std.testing.expectEqual(@as(u64, 1), model.version().active_tab);
}

test "tab selection resolves identity position and wrapping offset" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const second: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    try model.workspace.bootstrap(@enumFromInt(1), first, .{ .cols = 20, .rows = 5 });
    _ = try model.workspace.addCreated(.{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model.workspace.select(first.tab_id));

    const selection = (try model.selectTab(.{ .position = 1 })).?;

    try std.testing.expectEqualDeep(first, selection.previous);
    try std.testing.expectEqualDeep(second, selection.selected);
    try std.testing.expectEqualDeep(second, model.activeTabLocation().?);
    try std.testing.expectEqual(@as(u64, 0), model.version().tabs);
    try std.testing.expectEqual(@as(u64, 1), model.version().active_tab);

    try std.testing.expectEqualDeep(first, (try model.selectTab(.{ .offset = 1 })).?.selected);
    try std.testing.expectEqualDeep(second, (try model.selectTab(.{ .offset = -1 })).?.selected);
    try std.testing.expectEqualDeep(first, (try model.selectTab(.{ .tab_id = first.tab_id })).?.selected);
    try std.testing.expect((try model.selectTab(.{ .tab_id = first.tab_id })) == null);
    try std.testing.expect((try model.selectTab(.{ .position = 9 })) == null);
    try std.testing.expect((try model.selectTab(.{ .offset = 2 })) == null);
    try std.testing.expectError(error.TabNotFound, model.selectTab(.{ .tab_id = @enumFromInt(9) }));
    try std.testing.expectEqual(@as(u64, 4), model.version().active_tab);
}

test "sidebar visibility advances only the chrome revision" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    try std.testing.expect(model.sidebarVisible());
    try std.testing.expect(model.setSidebarVisible(true) == null);
    try std.testing.expectEqualDeep(Version{}, model.version());

    const hidden = model.toggleSidebar();

    try std.testing.expect(!hidden.visible);
    try std.testing.expect(!model.sidebarVisible());
    try std.testing.expectEqual(@as(u64, 1), hidden.chrome_revision);
    try std.testing.expectEqual(Version{ .chrome = 1 }, model.version());
    try std.testing.expect(model.setSidebarVisible(false) == null);

    const shown = model.setSidebarVisible(true).?;

    try std.testing.expect(shown.visible);
    try std.testing.expect(model.sidebarVisible());
    try std.testing.expectEqual(@as(u64, 2), shown.chrome_revision);
    try std.testing.expectEqual(Version{ .chrome = 2 }, model.version());
}

test "configuration adoption commits generation sidebar and pane gaps once" {
    var model = Model.initWithConfiguration(std.testing.allocator, true, 1);
    defer model.deinit();

    const changed = try model.applyConfiguration(.{
        .generation = 2,
        .sidebar_visible = false,
        .pane_gaps = false,
    });

    try std.testing.expectEqual(@as(u64, 2), changed.generation);
    try std.testing.expectEqual(@as(u64, 1), changed.configuration_revision);
    try std.testing.expect(!changed.sidebar.?.visible);
    try std.testing.expect(changed.pane_gaps_changed);
    try std.testing.expectEqual(@as(u64, 1), changed.panes_revision);
    try std.testing.expectEqual(@as(u64, 2), model.configurationGeneration());
    try std.testing.expect(!model.sidebarVisible());
    try std.testing.expect(!model.paneGaps());
    try std.testing.expectEqual(Version{
        .configuration = 1,
        .panes = 1,
        .chrome = 1,
    }, model.version());

    const semantic_noop = try model.applyConfiguration(.{
        .generation = 3,
        .sidebar_visible = false,
        .pane_gaps = false,
    });

    try std.testing.expect(semantic_noop.sidebar == null);
    try std.testing.expect(!semantic_noop.pane_gaps_changed);
    try std.testing.expectEqual(Version{
        .configuration = 2,
        .panes = 1,
        .chrome = 1,
    }, model.version());
}

test "configuration adoption rejects an old generation without partial state" {
    var model = Model.initWithConfiguration(std.testing.allocator, true, 4);
    defer model.deinit();
    const version = model.version();

    try std.testing.expectError(error.StaleConfiguration, model.applyConfiguration(.{
        .generation = 4,
        .sidebar_visible = false,
        .pane_gaps = false,
    }));

    try std.testing.expectEqual(@as(u64, 4), model.configurationGeneration());
    try std.testing.expect(model.sidebarVisible());
    try std.testing.expect(model.paneGaps());
    try std.testing.expectEqualDeep(version, model.version());
}

test "client diagnostics publish only changed valid text" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    try std.testing.expect(model.diagnostic() == null);
    try std.testing.expectEqual(Change.changed, try model.setDiagnostic("Lua failed: {s}", .{"boom"}));
    try std.testing.expectEqualStrings("Lua failed: boom", model.diagnostic().?);
    try std.testing.expectEqual(Version{ .diagnostic = 1 }, model.version());
    try std.testing.expectEqual(Change.unchanged, try model.setDiagnostic("Lua failed: {s}", .{"boom"}));
    try std.testing.expectEqual(Version{ .diagnostic = 1 }, model.version());

    var invalid: lua_config.Diagnostic = .{};
    invalid.buffer[0] = 0xff;
    invalid.len = 1;
    try std.testing.expectError(error.InvalidClientDiagnostic, model.replaceDiagnostic(invalid));
    invalid.len = invalid.buffer.len + 1;
    try std.testing.expectError(error.InvalidClientDiagnostic, model.replaceDiagnostic(invalid));
    try std.testing.expectEqualStrings("Lua failed: boom", model.diagnostic().?);

    try std.testing.expectEqual(Change.changed, model.clearDiagnostic());
    try std.testing.expect(model.diagnostic() == null);
    try std.testing.expectEqual(Change.unchanged, model.clearDiagnostic());
    try std.testing.expectEqual(Version{ .diagnostic = 2 }, model.version());
}

test "callback context is a value projection of committed client state" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    try std.testing.expectEqualDeep(lua_config.CallbackContext{
        .sidebar_visible = true,
        .tab_count = 0,
        .active_tab_index = 0,
        .pane_count = 0,
        .focused_pane_id = 0,
    }, model.callbackContext());

    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(3) },
        .tab_id = @enumFromInt(5),
    };
    const pane_id: schema.PaneId = @enumFromInt(7);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 20, .rows = 5 });
    _ = model.toggleSidebar();

    try std.testing.expectEqualDeep(lua_config.CallbackContext{
        .sidebar_visible = false,
        .tab_count = 1,
        .active_tab_index = 0,
        .pane_count = 1,
        .focused_pane_id = schema.id.raw(pane_id),
    }, model.callbackContext());
}

test "plugin execution is single flight and completion matches its exact identity" {
    var model = Model.initWithConfiguration(std.testing.allocator, true, 7);
    defer model.deinit();

    const first = (try model.beginPluginExecution()).?;

    try std.testing.expectEqual(@as(u64, 1), @intFromEnum(first.id));
    try std.testing.expectEqual(@as(u64, 7), first.configuration_generation);
    try std.testing.expectEqualDeep(first, model.pluginExecution().?);
    try std.testing.expect((try model.beginPluginExecution()) == null);
    try std.testing.expect(model.finishPluginExecution(@enumFromInt(99)) == null);
    try std.testing.expectEqualDeep(first, model.pluginExecution().?);
    try std.testing.expectEqualDeep(first, model.finishPluginExecution(first.id).?);
    try std.testing.expect(model.pluginExecution() == null);

    const second = (try model.beginPluginExecution()).?;

    try std.testing.expectEqual(@as(u64, 2), @intFromEnum(second.id));
    try std.testing.expectEqualDeep(Version{}, model.version());
}

test "plugin execution retains its launch generation across configuration reload" {
    var model = Model.initWithConfiguration(std.testing.allocator, true, 3);
    defer model.deinit();
    const execution = (try model.beginPluginExecution()).?;

    _ = try model.applyConfiguration(.{
        .generation = 4,
        .sidebar_visible = true,
        .pane_gaps = true,
    });

    try std.testing.expectEqual(@as(u64, 3), model.pluginExecution().?.configuration_generation);
    try std.testing.expectEqualDeep(execution, model.finishPluginExecution(execution.id).?);
}

test "plugin execution identity exhaustion cannot publish a partial reservation" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    model.next_plugin_execution_id = std.math.maxInt(u64);

    const last = (try model.beginPluginExecution()).?;

    try std.testing.expectEqual(std.math.maxInt(u64), @intFromEnum(last.id));
    _ = model.finishPluginExecution(last.id);
    try std.testing.expectError(error.PluginExecutionIdExhausted, model.beginPluginExecution());
    try std.testing.expect(model.pluginExecution() == null);
}

test "clipboard capture is single flight and completion matches its exact identity" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const target: attachments.Target = .{
        .pane_id = @enumFromInt(7),
        .pane_generation = 3,
    };

    const first = (try model.beginClipboardCapture(target)).?;

    try std.testing.expectEqual(@as(u64, 1), @intFromEnum(first.id));
    try std.testing.expectEqualDeep(target, first.target);
    try std.testing.expectEqualDeep(first, model.clipboardCapture().?);
    try std.testing.expect((try model.beginClipboardCapture(target)) == null);
    try std.testing.expect(model.finishClipboardCapture(@enumFromInt(99)) == null);
    try std.testing.expectEqualDeep(first, model.clipboardCapture().?);
    try std.testing.expectEqualDeep(first, model.finishClipboardCapture(first.id).?);
    try std.testing.expect(model.clipboardCapture() == null);

    const second = (try model.beginClipboardCapture(target)).?;

    try std.testing.expectEqual(@as(u64, 2), @intFromEnum(second.id));
    try std.testing.expectEqualDeep(Version{}, model.version());
}

test "clipboard capture validation and identity exhaustion leave no reservation" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    try std.testing.expectError(error.InvalidAttachmentTarget, model.beginClipboardCapture(.{
        .pane_id = .invalid,
        .pane_generation = 1,
    }));
    try std.testing.expect(model.clipboardCapture() == null);

    model.next_clipboard_capture_id = std.math.maxInt(u64);
    const last = (try model.beginClipboardCapture(.{
        .pane_id = @enumFromInt(4),
        .pane_generation = 2,
    })).?;

    try std.testing.expectEqual(std.math.maxInt(u64), @intFromEnum(last.id));
    _ = model.finishClipboardCapture(last.id);
    try std.testing.expectError(
        error.ClipboardCaptureIdExhausted,
        model.beginClipboardCapture(last.target),
    );
    try std.testing.expect(model.clipboardCapture() == null);
}

test "host resize commits resolved geometry once" {
    const initial: schema.TerminalSize = .{
        .cols = 80,
        .rows = 24,
        .cell_width_px = 10,
        .cell_height_px = 20,
    };
    var model = Model.initWithState(std.testing.allocator, .{
        .pane_gaps = true,
        .host_size = initial,
        .host_capabilities = .{
            .cell_width_px = 10,
            .cell_height_px = 20,
        },
    });
    defer model.deinit();
    const resized: schema.TerminalSize = .{
        .cols = 100,
        .rows = 30,
        .cell_width_px = 10,
        .cell_height_px = 20,
    };

    const commit = (try model.reconcileHost(.{
        .capabilities = model.hostCapabilities(),
        .size = resized,
    })).?.resize.?;

    try std.testing.expectEqualDeep(initial, commit.previous);
    try std.testing.expectEqualDeep(resized, commit.current);
    try std.testing.expect(commit.grid_changed);
    try std.testing.expect(!commit.cell_size_changed);
    try std.testing.expectEqual(@as(u64, 1), commit.host_revision);
    try std.testing.expectEqualDeep(resized, model.hostSize());
    try std.testing.expectEqual(Version{ .host = 1 }, model.version());
    try std.testing.expect((try model.reconcileHost(.{
        .capabilities = model.hostCapabilities(),
        .size = resized,
    })) == null);
    try std.testing.expectEqual(Version{ .host = 1 }, model.version());
}

test "host resize rejects invalid and oversized grids without partial state" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const size = model.hostSize();
    const version = model.version();

    try std.testing.expectError(error.InvalidTerminalSize, model.reconcileHost(.{
        .capabilities = model.hostCapabilities(),
        .size = .{ .cols = 0, .rows = 24 },
    }));
    try std.testing.expectError(error.ScreenTooLarge, model.reconcileHost(.{
        .capabilities = model.hostCapabilities(),
        .size = .{
            .cols = std.math.maxInt(u16),
            .rows = std.math.maxInt(u16),
        },
    }));

    try std.testing.expectEqualDeep(size, model.hostSize());
    try std.testing.expectEqualDeep(version, model.version());
}

test "host support probes commit independently and expiry settles only unknown values" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const graphics_commit = (try model.observeHostCapability(.{
        .kitty_graphics = .supported,
    })).?;
    try std.testing.expect(graphics_commit.resize == null);
    try std.testing.expectEqual(kitty.Support.supported, model.hostCapabilities().kitty_graphics);
    try std.testing.expectEqual(kitty.Support.unknown, model.hostCapabilities().kitty_zlib);

    _ = try model.observeHostCapability(.{ .kitty_zlib = .unsupported });
    const expired = (try model.expireHostCapabilities()).?;

    try std.testing.expect(expired.resize == null);
    try std.testing.expectEqual(kitty.Support.supported, model.hostCapabilities().kitty_graphics);
    try std.testing.expectEqual(kitty.Support.unsupported, model.hostCapabilities().kitty_zlib);
    try std.testing.expectEqual(kitty.Support.unsupported, model.hostCapabilities().mouse_pixels);
    try std.testing.expectEqual(Version{ .host_capabilities = 3 }, model.version());
    try std.testing.expect((try model.expireHostCapabilities()) == null);
    try std.testing.expectEqual(Version{ .host_capabilities = 3 }, model.version());
}

test "host pixel observations commit raw measurements and resolved geometry atomically" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const window = (try model.observeHostCapability(.{ .window_pixels = .{
        .width = 800,
        .height = 480,
    } })).?;

    try std.testing.expectEqual(schema.TerminalSize{
        .cols = 80,
        .rows = 24,
        .cell_width_px = 10,
        .cell_height_px = 20,
    }, model.hostSize());
    try std.testing.expect(window.capabilities != null);
    try std.testing.expect(window.resize != null);
    try std.testing.expectEqual(Version{
        .host = 1,
        .host_capabilities = 1,
    }, model.version());

    const cell = (try model.observeHostCapability(.{ .cell_pixels = .{
        .width = 12,
        .height = 24,
    } })).?;
    try std.testing.expect(cell.resize != null);
    try std.testing.expectEqual(@as(u16, 12), model.hostSize().cell_width_px);
    try std.testing.expectEqual(@as(u16, 24), model.hostSize().cell_height_px);

    const later_window = (try model.observeHostCapability(.{ .window_pixels = .{
        .width = 1600,
        .height = 960,
    } })).?;
    try std.testing.expect(later_window.resize == null);
    try std.testing.expectEqual(@as(u16, 12), model.hostSize().cell_width_px);
    try std.testing.expectEqual(@as(u16, 24), model.hostSize().cell_height_px);
    try std.testing.expectEqual(Version{
        .host = 2,
        .host_capabilities = 3,
    }, model.version());
}

test "host reconciliation validates geometry before publishing capabilities" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capabilities = model.hostCapabilities();
    capabilities.window_width_px = 1200;
    const size = model.hostSize();
    const version = model.version();

    try std.testing.expectError(error.InconsistentHostGeometry, model.reconcileHost(.{
        .capabilities = capabilities,
        .size = size,
    }));
    try std.testing.expectError(error.ScreenTooLarge, model.reconcileHost(.{
        .capabilities = capabilities,
        .size = .{
            .cols = std.math.maxInt(u16),
            .rows = std.math.maxInt(u16),
        },
    }));

    try std.testing.expectEqualDeep(size, model.hostSize());
    try std.testing.expectEqualDeep(HostCapabilities{}, model.hostCapabilities());
    try std.testing.expectEqualDeep(version, model.version());
}

test "workspace list collapse advances only the chrome revision" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    try std.testing.expect(!model.workspaceListCollapsed());
    try std.testing.expect(model.setWorkspaceListCollapsed(false) == null);
    try std.testing.expectEqualDeep(Version{}, model.version());

    const collapsed = model.toggleWorkspaceList();

    try std.testing.expect(collapsed.collapsed);
    try std.testing.expect(model.workspaceListCollapsed());
    try std.testing.expectEqual(@as(u64, 1), collapsed.chrome_revision);
    try std.testing.expectEqual(Version{ .chrome = 1 }, model.version());
    try std.testing.expect(model.setWorkspaceListCollapsed(true) == null);

    const expanded = model.setWorkspaceListCollapsed(false).?;

    try std.testing.expect(!expanded.collapsed);
    try std.testing.expect(!model.workspaceListCollapsed());
    try std.testing.expectEqual(@as(u64, 2), expanded.chrome_revision);
    try std.testing.expectEqual(Version{ .chrome = 2 }, model.version());
}

test "workspace list reconciliation owns navigation state and one isolated revision" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    var first_name = [_]u8{ 't', 'e', 'l', 'a', 'r' };
    var first_path = [_]u8{ '/', 'w', '/', 't', 'e', 'l', 'a', 'r' };
    const entries = [_]workspace_list_mod.EntryInput{
        .{ .workspace = @enumFromInt(1), .name = &first_name, .path = &first_path, .tab_count = 2 },
        .{ .workspace = @enumFromInt(2), .name = "api", .path = "/work/api", .tab_count = 1 },
    };

    const commit = (try model.reconcileWorkspaceList(.{
        .revision = 7,
        .entries = &entries,
    })).?;
    @memset(&first_name, 'x');
    @memset(&first_path, 'x');

    try std.testing.expectEqual(@as(u64, 7), commit.runtime_revision);
    try std.testing.expectEqual(@as(usize, 2), commit.count);
    try std.testing.expectEqual(@as(u64, 1), commit.workspace_list_revision);
    try std.testing.expectEqual(Version{ .workspace_list = 1 }, model.version());
    try std.testing.expectEqualStrings("telar", model.workspaceListSnapshot().nameAt(0));
    try std.testing.expectEqualStrings("/w/telar", model.workspaceListSnapshot().pathAt(0));
    try std.testing.expect(model.knowsWorkspace(@enumFromInt(1)));
    try std.testing.expect(!model.knowsWorkspace(@enumFromInt(9)));
    try std.testing.expectEqual(@as(schema.WorkspaceId, @enumFromInt(2)), model.workspaceAtPosition(1).?);
    try std.testing.expect(model.workspaceAtPosition(2) == null);

    try std.testing.expect((try model.reconcileWorkspaceList(.{
        .revision = 6,
        .entries = &entries,
    })) == null);
    try std.testing.expectEqual(Version{ .workspace_list = 1 }, model.version());

    const duplicate = [_]workspace_list_mod.EntryInput{
        .{ .workspace = @enumFromInt(3), .name = "one", .path = "/one", .tab_count = 1 },
        .{ .workspace = @enumFromInt(3), .name = "two", .path = "/two", .tab_count = 1 },
    };
    try std.testing.expectError(error.DuplicateWorkspace, model.reconcileWorkspaceList(.{
        .revision = 8,
        .entries = &duplicate,
    }));
    try std.testing.expectEqual(Version{ .workspace_list = 1 }, model.version());
    try std.testing.expectEqualStrings("telar", model.workspaceListSnapshot().nameAt(0));
}

test "proxy status reconciliation commits only changed runtime state" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    try std.testing.expect(model.reconcileProxyStatus(false) == null);
    try std.testing.expect(!model.proxyTlsActive());
    try std.testing.expectEqualDeep(Version{}, model.version());

    const enabled = model.reconcileProxyStatus(true).?;

    try std.testing.expect(!enabled.previous);
    try std.testing.expect(enabled.active);
    try std.testing.expectEqual(@as(u64, 1), enabled.proxy_status_revision);
    try std.testing.expect(model.proxyTlsActive());
    try std.testing.expectEqual(Version{ .proxy_status = 1 }, model.version());
    try std.testing.expect(model.reconcileProxyStatus(true) == null);
    try std.testing.expectEqual(Version{ .proxy_status = 1 }, model.version());

    const disabled = model.reconcileProxyStatus(false).?;

    try std.testing.expect(disabled.previous);
    try std.testing.expect(!disabled.active);
    try std.testing.expectEqual(@as(u64, 2), disabled.proxy_status_revision);
    try std.testing.expect(!model.proxyTlsActive());
    try std.testing.expectEqual(Version{ .proxy_status = 2 }, model.version());
}

test "system metrics reconciliation owns the latest replica and one isolated revision" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const first = (try model.reconcileSystemMetrics(.{
        .runtime_revision = 4,
        .cpu_percent = 25,
        .memory_used_decigib = 123,
        .battery_percent = null,
    })).?;

    try std.testing.expectEqual(@as(u64, 4), first.runtime_revision);
    try std.testing.expectEqual(@as(u64, 1), first.system_metrics_revision);
    try std.testing.expectEqual(Version{ .system_metrics = 1 }, model.version());
    try std.testing.expectEqualDeep(SystemMetrics{
        .runtime_revision = 4,
        .cpu_percent = 25,
        .memory_used_decigib = 123,
        .battery_percent = null,
    }, model.systemMetrics().?);

    try std.testing.expect((try model.reconcileSystemMetrics(.{
        .runtime_revision = 3,
        .cpu_percent = 10,
        .memory_used_decigib = 20,
        .battery_percent = 90,
    })) == null);
    try std.testing.expectEqual(Version{ .system_metrics = 1 }, model.version());

    const second = (try model.reconcileSystemMetrics(.{
        .runtime_revision = 5,
        .cpu_percent = 50,
        .memory_used_decigib = 10,
        .battery_percent = 80,
    })).?;

    try std.testing.expectEqual(@as(u64, 2), second.system_metrics_revision);
    try std.testing.expectEqual(@as(?u8, 80), model.systemMetrics().?.battery_percent);
    try std.testing.expectEqual(Version{ .system_metrics = 2 }, model.version());
}

test "rejected system metrics preserve the latest replica and version" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const initial: SystemMetrics = .{
        .runtime_revision = 1,
        .cpu_percent = 30,
        .memory_used_decigib = 80,
        .battery_percent = null,
    };
    _ = try model.reconcileSystemMetrics(initial);

    try std.testing.expectError(error.InvalidMetricsRevision, model.reconcileSystemMetrics(.{
        .runtime_revision = 0,
        .cpu_percent = 30,
        .memory_used_decigib = 80,
        .battery_percent = null,
    }));
    try std.testing.expectError(error.InvalidMetricsValue, model.reconcileSystemMetrics(.{
        .runtime_revision = 2,
        .cpu_percent = 101,
        .memory_used_decigib = 80,
        .battery_percent = null,
    }));
    try std.testing.expectError(error.InvalidMetricsValue, model.reconcileSystemMetrics(.{
        .runtime_revision = 3,
        .cpu_percent = 30,
        .memory_used_decigib = 80,
        .battery_percent = 101,
    }));

    try std.testing.expectEqualDeep(initial, model.systemMetrics().?);
    try std.testing.expectEqual(Version{ .system_metrics = 1 }, model.version());
}

test "notification lifecycle is model-owned and versioned by semantic change" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    var title = [_]u8{ 'R', 'e', 'a', 'd', 'y' };
    const tab_id: schema.TabId = @enumFromInt(7);
    const started_ns: u64 = 100;

    const publication = model.publishNotification(started_ns, .{
        .level = .success,
        .title = &title,
        .message = "Open completed tab",
        .target = .{ .select_tab = tab_id },
    });
    @memset(&title, 'x');

    try std.testing.expectEqual(Version{ .notifications = 1 }, model.version());
    try std.testing.expectEqualStrings("Ready", model.notificationSnapshot().itemAt(0).?.title());
    try std.testing.expectEqual(
        started_ns + std.time.ns_per_s / 60,
        model.nextNotificationDeadline(started_ns, std.time.ns_per_s / 60).?,
    );

    const activation_ns = started_ns + notifications.transition_duration_ns;
    const activation = model.activateNotification(publication.id, activation_ns).?;

    try std.testing.expectEqual(tab_id, activation.target.select_tab);
    try std.testing.expectEqual(@as(u64, 2), activation.notifications_revision);
    try std.testing.expectEqual(Version{ .notifications = 2 }, model.version());
    try std.testing.expect(model.activateNotification(publication.id, activation_ns) == null);
    try std.testing.expectEqual(Version{ .notifications = 2 }, model.version());

    const removal = model.advanceNotifications(activation_ns + notifications.transition_duration_ns).?;

    try std.testing.expectEqual(@as(u64, 3), removal.notifications_revision);
    try std.testing.expect(!model.notificationSnapshot().hasItems());
    try std.testing.expectEqual(Version{ .notifications = 3 }, model.version());

    const second = model.publishNotification(1000, .{ .title = "Saved", .message = "Done" });
    const dismissed = model.dismissNotification(second.id, 1001).?;

    try std.testing.expectEqual(@as(u64, 5), dismissed.notifications_revision);
    try std.testing.expect(model.dismissNotification(second.id, 1001) == null);
    try std.testing.expectEqual(Version{ .notifications = 5 }, model.version());
}

test "agent reconciliation owns labels versions and existing status transitions" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const key: agents.AgentKey = .{ .pane_id = @enumFromInt(7), .pane_generation = 2 };
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    var title = [_]u8{ 'f', 'i', 'r', 's', 't' };
    var agent: agents.AgentInput = .{
        .key = key,
        .location = location,
        .pane_index = 3,
        .session_title = &title,
        .provider = .codex,
        .status = .working,
    };

    const first = (try model.reconcileAgentSnapshot(.{
        .revision = 4,
        .agents = &.{agent},
    })).?;
    title[0] = 'x';

    try std.testing.expectEqual(@as(u64, 4), first.runtime_revision);
    try std.testing.expectEqual(@as(usize, 1), first.count);
    try std.testing.expectEqual(@as(usize, 0), first.status_changes.slice().len);
    try std.testing.expectEqual(Version{ .agents = 1 }, model.version());
    try std.testing.expectEqualStrings("first", model.agentSnapshot().find(key).?.sessionTitle());
    try std.testing.expect(model.knowsAgent(key));
    try std.testing.expect(model.sidebarAnimationActive());

    agent.session_title = "second";
    agent.status = .ready;
    const second = (try model.reconcileAgentSnapshot(.{
        .revision = 5,
        .agents = &.{agent},
    })).?;
    const change = second.status_changes.slice()[0];

    try std.testing.expectEqual(@as(u64, 2), second.agent_revision);
    try std.testing.expectEqual(@as(usize, 1), second.status_changes.slice().len);
    try std.testing.expectEqualDeep(key, change.key);
    try std.testing.expectEqual(schema.AgentStatus.working, change.previous);
    try std.testing.expectEqual(schema.AgentStatus.ready, change.current);
    try std.testing.expectEqual(@as(u16, 3), change.pane_index);
    try std.testing.expectEqual(schema.AgentProvider.codex, change.provider);
    try std.testing.expect(!model.sidebarAnimationActive());
    try std.testing.expect((try model.reconcileAgentSnapshot(.{
        .revision = 5,
        .agents = &.{agent},
    })) == null);
    try std.testing.expectEqual(Version{ .agents = 2 }, model.version());
}

test "sidebar animation advances its own revision only while active" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    var agent: agents.AgentInput = .{
        .key = .{ .pane_id = @enumFromInt(7), .pane_generation = 2 },
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        },
        .pane_index = 1,
        .provider = .codex,
        .status = .ready,
    };
    _ = try model.reconcileAgentSnapshot(.{ .revision = 1, .agents = &.{agent} });

    try std.testing.expect(model.advanceSidebarAnimation() == null);
    try std.testing.expectEqual(@as(u8, 0), model.sidebarAnimationFrame());
    try std.testing.expectEqual(Version{ .agents = 1 }, model.version());

    agent.status = .working;
    _ = try model.reconcileAgentSnapshot(.{ .revision = 2, .agents = &.{agent} });
    const first = model.advanceSidebarAnimation().?;
    const second = model.advanceSidebarAnimation().?;

    try std.testing.expectEqual(@as(u8, 1), first.frame);
    try std.testing.expectEqual(@as(u64, 1), first.sidebar_animation_revision);
    try std.testing.expectEqual(@as(u8, 2), second.frame);
    try std.testing.expectEqual(@as(u64, 2), second.sidebar_animation_revision);
    try std.testing.expectEqual(@as(u8, 2), model.sidebarAnimationFrame());
    try std.testing.expectEqual(Version{
        .agents = 2,
        .sidebar_animation = 2,
    }, model.version());
}

test "rejected agent reconciliation preserves replica and version" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const agent: agents.AgentInput = .{
        .key = .{ .pane_id = @enumFromInt(7), .pane_generation = 2 },
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        },
        .pane_index = 1,
        .provider = .codex,
        .status = .working,
    };
    _ = try model.reconcileAgentSnapshot(.{ .revision = 1, .agents = &.{agent} });

    try std.testing.expectError(error.DuplicateAgent, model.reconcileAgentSnapshot(.{
        .revision = 2,
        .agents = &.{ agent, agent },
    }));
    const oversized: [agents.max_agents + 1]agents.AgentInput = @splat(agent);
    try std.testing.expectError(error.TooManyAgents, model.reconcileAgentSnapshot(.{
        .revision = 3,
        .agents = &oversized,
    }));

    try std.testing.expectEqual(Version{ .agents = 1 }, model.version());
    try std.testing.expectEqual(@as(u64, 1), model.agentSnapshot().revision);
    try std.testing.expect(model.knowsAgent(agent.key));
}

test "agent navigation and focused attachments derive from committed client state" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();
    const first: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const second: schema.TabLocation = .{
        .workspace = first.workspace,
        .tab_id = @enumFromInt(2),
    };
    const local_key: agents.AgentKey = .{
        .pane_id = @enumFromInt(1),
        .pane_generation = 4,
    };
    const remote_key: agents.AgentKey = .{
        .pane_id = @enumFromInt(9),
        .pane_generation = 3,
    };
    try model.workspace.bootstrap(local_key.pane_id, first, .{ .cols = 20, .rows = 5 });
    const agent_entries = [_]agents.AgentInput{
        .{
            .key = local_key,
            .location = first,
            .pane_index = 1,
            .provider = .claude,
            .status = .ready,
        },
        .{
            .key = remote_key,
            .location = .{
                .workspace = .{ .workspace = @enumFromInt(3) },
                .tab_id = @enumFromInt(6),
            },
            .pane_index = 2,
            .provider = .codex,
            .status = .working,
        },
    };
    _ = try model.reconcileAgentSnapshot(.{ .revision = 1, .agents = &agent_entries });

    try std.testing.expectEqualDeep(local_key, model.focusedAttachmentAgent().?);
    try std.testing.expectEqualDeep(attachments.Target{
        .pane_id = local_key.pane_id,
        .pane_generation = local_key.pane_generation,
    }, model.focusedAttachmentTarget().?);
    try std.testing.expectEqualDeep(LocalAgentNavigation{
        .pane_id = local_key.pane_id,
        .select_tab = null,
    }, model.planAgentNavigation(local_key).?.local);
    try std.testing.expectEqualDeep(AgentHandoff{
        .pane_id = remote_key.pane_id,
        .fallback_workspace = @enumFromInt(3),
    }, model.planAgentNavigation(remote_key).?.handoff);

    _ = try model.workspace.addCreated(.{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });

    try std.testing.expect(model.focusedAttachmentAgent() == null);
    try std.testing.expect(model.focusedAttachmentTarget() == null);
    try std.testing.expectEqualDeep(LocalAgentNavigation{
        .pane_id = local_key.pane_id,
        .select_tab = first.tab_id,
    }, model.planAgentNavigation(local_key).?.local);
    try std.testing.expect(model.planAgentNavigation(.{
        .pane_id = remote_key.pane_id,
        .pane_generation = remote_key.pane_generation + 1,
    }) == null);
}

test "pane focus resolves identity and direction through one visible revision" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const first: schema.PaneId = @enumFromInt(1);
    const second: schema.PaneId = @enumFromInt(2);
    const area: ui.Rect = .{ .w = 80, .h = 24 };
    try model.workspace.bootstrap(first, location, .{ .cols = 80, .rows = 24 });
    try model.workspace.active().?.model.split(first, second, location, .horizontal, area);

    const directional = model.focusPane(.{
        .target = .{ .direction = .left },
        .area = area,
    }).?;

    try std.testing.expectEqualDeep(location, directional.location);
    try std.testing.expectEqual(second, directional.previous);
    try std.testing.expectEqual(first, directional.focused);
    try std.testing.expect(!directional.geometry_changed);
    try std.testing.expectEqual(@as(u64, 1), model.version().panes);

    try std.testing.expect(model.workspace.active().?.model.toggleFullscreen());
    const identified = model.focusPane(.{
        .target = .{ .pane_id = second },
        .area = area,
    }).?;

    try std.testing.expectEqual(first, identified.previous);
    try std.testing.expectEqual(second, identified.focused);
    try std.testing.expect(identified.geometry_changed);
    try std.testing.expect((model.focusPane(.{
        .target = .{ .pane_id = second },
        .area = area,
    })) == null);
    try std.testing.expect((model.focusPane(.{
        .target = .{ .pane_id = @enumFromInt(9) },
        .area = area,
    })) == null);
    try std.testing.expect((model.focusPane(.{
        .target = .{ .direction = .right },
        .area = area,
    })) == null);
    try std.testing.expectEqual(Version{ .panes = 2 }, model.version());
}

test "pane resize owns direction resolution geometry and visible revisions" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const first: schema.PaneId = @enumFromInt(1);
    const second: schema.PaneId = @enumFromInt(2);
    const area: ui.Rect = .{ .w = 101, .h = 41 };
    try model.workspace.bootstrap(first, location, .{ .cols = 101, .rows = 41 });
    const active = &model.workspace.active().?.model;
    try active.split(first, second, location, .horizontal, area);
    try std.testing.expect(active.focusPane(first));
    const width_before = active.contentSize(first, area).?.cols;

    const resized = model.resizePane(.{ .direction = .right, .area = area }).?;

    try std.testing.expectEqualDeep(location, resized.location);
    try std.testing.expectEqual(first, resized.focused);
    try std.testing.expectEqual(model.version().panes, resized.panes_revision);
    try std.testing.expectEqualDeep(area, resized.area);
    try std.testing.expect(!resized.fullscreen);
    try std.testing.expect(active.contentSize(first, area).?.cols > width_before);
    try std.testing.expectEqual(Version{ .panes = 1 }, model.version());
    try std.testing.expect((model.resizePane(.{ .direction = .up, .area = area })) == null);
    try std.testing.expectEqual(Version{ .panes = 1 }, model.version());

    try std.testing.expect(active.toggleFullscreen());
    const fullscreen_resize = model.resizePane(.{ .direction = .left, .area = area }).?;
    try std.testing.expect(active.layout.isFullscreen());
    try std.testing.expectEqual(model.version().panes, fullscreen_resize.panes_revision);
    try std.testing.expect(fullscreen_resize.fullscreen);
    try std.testing.expectEqual(Version{ .panes = 2 }, model.version());
    try std.testing.expect(active.toggleFullscreen());
    try std.testing.expectEqual(width_before, active.contentSize(first, area).?.cols);

    while (model.resizePane(.{ .direction = .right, .area = .{ .w = 7, .h = 3 } }) != null) {}
    const version_at_limit = model.version();
    try std.testing.expect((model.resizePane(.{
        .direction = .right,
        .area = .{ .w = 7, .h = 3 },
    })) == null);
    try std.testing.expectEqualDeep(version_at_limit, model.version());

    model.workspace.deinit();
    try std.testing.expect((model.resizePane(.{ .direction = .right, .area = area })) == null);
    try std.testing.expectEqualDeep(version_at_limit, model.version());
}

test "pane fullscreen preserves tiled geometry through two visible revisions" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const first: schema.PaneId = @enumFromInt(1);
    const second: schema.PaneId = @enumFromInt(2);
    const area: ui.Rect = .{ .w = 101, .h = 41 };
    try model.workspace.bootstrap(first, location, .{ .cols = 101, .rows = 41 });
    const active = &model.workspace.active().?.model;
    try std.testing.expect(model.togglePaneFullscreen(.{ .area = area }) == null);
    try std.testing.expectEqual(Version{}, model.version());
    try active.split(first, second, location, .horizontal, area);
    try std.testing.expect(active.focusPane(first));
    const first_tiled = active.contentSize(first, area).?;
    const second_tiled = active.contentSize(second, area).?;

    const entered = model.togglePaneFullscreen(.{ .area = area }).?;

    try std.testing.expectEqualDeep(location, entered.location);
    try std.testing.expectEqual(first, entered.focused);
    try std.testing.expectEqual(model.version().panes, entered.panes_revision);
    try std.testing.expectEqualDeep(area, entered.area);
    try std.testing.expect(entered.fullscreen);
    try std.testing.expectEqual(schema.TerminalSize{ .cols = area.w, .rows = area.h }, active.contentSize(first, area).?);
    try std.testing.expect(active.contentSize(second, area) == null);
    try std.testing.expectEqual(Version{ .panes = 1 }, model.version());

    const exited = model.togglePaneFullscreen(.{ .area = area }).?;

    try std.testing.expect(!exited.fullscreen);
    try std.testing.expectEqual(first_tiled, active.contentSize(first, area).?);
    try std.testing.expectEqual(second_tiled, active.contentSize(second, area).?);
    try std.testing.expectEqual(Version{ .panes = 2 }, model.version());

    model.workspace.deinit();
    try std.testing.expect(model.togglePaneFullscreen(.{ .area = area }) == null);
    try std.testing.expectEqual(Version{ .panes = 2 }, model.version());
}

test "pane closure planning requires the active attached pane without mutation" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 20, .rows = 5 });

    const closure = model.planPaneClosure().?;

    try std.testing.expectEqual(pane_id, closure.pane_id);
    try std.testing.expectEqualDeep(location, closure.location);
    try std.testing.expectEqualDeep(Version{}, model.version());

    model.workspace.findPane(pane_id).?.attached = false;

    try std.testing.expect(model.planPaneClosure() == null);
    try std.testing.expectEqualDeep(Version{}, model.version());
}

test "active pane retirement advances the visible pane revision once" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const first: schema.PaneId = @enumFromInt(1);
    const second: schema.PaneId = @enumFromInt(2);
    try model.workspace.bootstrap(first, location, .{ .cols = 40, .rows = 10 });
    try model.workspace.active().?.model.split(
        first,
        second,
        location,
        .horizontal,
        .{ .w = 40, .h = 10 },
    );

    const retirement = model.retirePane(second);

    try std.testing.expect(retirement == .retired);
    try std.testing.expectEqual(second, retirement.retired.pane_id);
    try std.testing.expectEqualDeep(location, retirement.retired.location);
    try std.testing.expect(retirement.retired.active);
    try std.testing.expect(!retirement.retired.tab_empty);
    try std.testing.expect(model.workspace.findPane(second) == null);
    try std.testing.expectEqual(first, model.workspace.active().?.model.layout.focused().?);
    try std.testing.expectEqualDeep(Version{ .panes = 1 }, model.version());

    const repeated = model.retirePane(second);

    try std.testing.expect(repeated == .stale);
    try std.testing.expectEqual(second, repeated.stale);
    try std.testing.expectEqualDeep(Version{ .panes = 1 }, model.version());
}

test "inactive pane retirement changes membership without a visible revision" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const active: schema.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(1) };
    const inactive: schema.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(2) };
    const inactive_pane: schema.PaneId = @enumFromInt(2);
    try model.workspace.bootstrap(@enumFromInt(1), active, .{ .cols = 20, .rows = 5 });
    _ = try model.workspace.addCreated(.{
        .location = inactive,
        .position = 1,
        .label = "logs",
        .root_pane_id = inactive_pane,
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model.workspace.select(active.tab_id));

    const retirement = model.retirePane(inactive_pane);

    try std.testing.expect(retirement == .retired);
    try std.testing.expect(!retirement.retired.active);
    try std.testing.expect(retirement.retired.tab_empty);
    try std.testing.expect(model.workspace.findPane(inactive_pane) == null);
    try std.testing.expectEqualDeep(active, model.activeTabLocation().?);
    try std.testing.expectEqualDeep(Version{}, model.version());
}

test "split confirmation replaces a target retired during pane creation" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const target: schema.PaneId = @enumFromInt(1);
    const created: schema.PaneId = @enumFromInt(2);
    try model.workspace.bootstrap(target, location, .{ .cols = 40, .rows = 10 });
    try std.testing.expect(model.workspace.active().?.model.removePane(target));

    const commit = try model.commitPaneSplit(.{
        .split = .{
            .target_pane = target,
            .location = location,
            .axis = .horizontal,
            .area = .{ .w = 40, .h = 10 },
        },
        .new_pane = created,
    });

    try std.testing.expectEqual(PaneSplitDisposition.active, commit.disposition);
    try std.testing.expectEqual(Change.changed, commit.change);
    try std.testing.expect(model.workspace.findPane(target) == null);
    try std.testing.expect(model.workspace.findPane(created).?.attached);
    try std.testing.expectEqual(created, model.workspace.active().?.model.layout.focused().?);
    try std.testing.expectEqualDeep(Version{ .panes = 1 }, model.version());
}

test "inactive split confirmation retains membership without visible revision" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: schema.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(1) };
    const second: schema.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(2) };
    const target: schema.PaneId = @enumFromInt(1);
    const created: schema.PaneId = @enumFromInt(3);
    try model.workspace.bootstrap(target, first, .{ .cols = 40, .rows = 10 });
    _ = try model.workspace.addCreated(.{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 40, .rows = 10 });
    tabs_mod.Model.detachAll(model.workspace.find(first.tab_id).?);

    const commit = try model.commitPaneSplit(.{
        .split = .{
            .target_pane = target,
            .location = first,
            .axis = .vertical,
            .area = .{ .w = 40, .h = 10 },
        },
        .new_pane = created,
    });

    try std.testing.expectEqual(PaneSplitDisposition.inactive, commit.disposition);
    try std.testing.expectEqual(Change.unchanged, commit.change);
    try std.testing.expect(!model.workspace.findPane(created).?.attached);
    try std.testing.expectEqualDeep(Version{}, model.version());
    try std.testing.expect(model.recoverPaneSplit(.{
        .split = commitSplit(target, first, .vertical),
        .area = .{ .w = 40, .h = 10 },
    }) == .not_required);
}

test "split confirmation leaves a retired tab unrepresented" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: schema.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(1) };
    const second: schema.TabLocation = .{ .workspace = workspace, .tab_id = @enumFromInt(2) };
    const target: schema.PaneId = @enumFromInt(1);
    const created: schema.PaneId = @enumFromInt(3);
    try model.workspace.bootstrap(target, first, .{ .cols = 40, .rows = 10 });
    _ = try model.workspace.addCreated(.{
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 40, .rows = 10 });
    try std.testing.expect(model.workspace.remove(first.tab_id));

    const commit = try model.commitPaneSplit(.{
        .split = .{
            .target_pane = target,
            .location = first,
            .axis = .horizontal,
            .area = .{ .w = 40, .h = 10 },
        },
        .new_pane = created,
    });

    try std.testing.expectEqual(PaneSplitDisposition.stale, commit.disposition);
    try std.testing.expectEqual(Change.unchanged, commit.change);
    try std.testing.expect(model.workspace.findPane(created) == null);
    try std.testing.expectEqualDeep(Version{}, model.version());
}

fn commitSplit(target: schema.PaneId, location: schema.TabLocation, axis: layout_mod.Axis) PaneSplit {
    return .{
        .target_pane = target,
        .location = location,
        .axis = axis,
        .area = .{ .w = 40, .h = 10 },
    };
}
