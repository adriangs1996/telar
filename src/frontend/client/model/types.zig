//! Value contracts used by the ClientModel aggregate.

const std = @import("std");
const core = @import("telar-core");
const agents = @import("../../agents/root.zig");
const attachments = @import("../../attachments/root.zig");
const bars = @import("../../bars/root.zig");
const lua_config = @import("../../config/root.zig");
const graphics = @import("../../graphics/root.zig");
const input_capability = @import("../../input/root.zig");
const notifications = @import("../../notifications/root.zig");
const frontend_ui = @import("../../ui/root.zig");
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
    bars: u64 = 0,
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
    previous_layout_revision: u64,
    selected_layout_revision: u64,
    workspace_revision: u64,
    tabs_revision: u64,
    active_tab_revision: u64,
    panes_revision: u64,
    copy_revision: u64,
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
    created_root_pane_id: schema.PaneId,
    created_position: u16,
    previous_layout_revision: u64,
    created_layout_revision: u64,
    tabs_revision_before: u64,
    active_tab_revision_before: u64,
    copy_revision_before: u64,
    copy_released: bool,
    workspace_revision: u64,
    tabs_revision: u64,
    active_tab_revision: u64,
    panes_revision: u64,
    copy_revision: u64,
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

pub const WorkspaceActivation = struct {
    pane_id: schema.PaneId,
    location: schema.TabLocation,
    workspace_revision_before: u64,
    tabs_revision_before: u64,
    active_tab_revision_before: u64,
    panes_revision_before: u64,
    copy_revision_before: u64,
    copy_released: bool,
    workspace_revision: u64,
    tabs_revision: u64,
    active_tab_revision: u64,
    panes_revision: u64,
    copy_revision: u64,
};

pub const WorkspaceReplacement = struct {
    departure: WorkspaceDeparture,
    activation: WorkspaceActivation,
};

pub const WorkspaceActivationSeed = struct {
    pane_id: schema.PaneId,
    location: schema.TabLocation,
    version_before: Version,
};

pub const PaneAttachment = struct {
    pane_id: schema.PaneId,
    location: schema.TabLocation,
};

pub const PaneAttachmentConfirmation = enum {
    confirmed,
    stale,
};

pub const TabDetachmentPlan = struct {
    location: schema.TabLocation,
    panes: [multiplexer.max_panes]Pane = undefined,
    len: u8 = 0,
    owns_paste: bool = false,
    owns_reported_focus: bool = false,
    paste_marker_required: bool = false,
    focus_out_required: bool = false,

    pub const Pane = struct {
        pane_id: schema.PaneId,
        attached: bool,
    };

    /// Returns the exact panes captured for one synchronous tab detachment.
    ///
    /// ```zig
    /// for (plan.slice()) |pane| detach(pane.pane_id);
    /// ```
    pub fn slice(plan: *const TabDetachmentPlan) []const Pane {
        return plan.panes[0..plan.len];
    }
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
    panes_revision: u64,
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

pub const SidebarLayout = struct {
    visible: bool,
    width: u16 = frontend_ui.sidebar.default_width,
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
    bars: bars.Layout = .{},
    /// Borrowed only for the synchronous transition; copied into the model.
    window_title: []const u8 = "",
};

pub const max_window_title_template_bytes = 128;

pub const ConfigurationCommit = struct {
    generation: u64,
    configuration_revision: u64,
    sidebar: ?SidebarLayout,
    pane_gaps_changed: bool,
    panes_revision: u64,
    bars_changed: bool = false,
    bars_revision: u64 = 0,
};

pub const BarUpdateCommit = struct {
    generation: u64,
    position: bars.Position,
    bars_revision: u64,
};

pub const BarUpdateInput = struct {
    generation: u64,
    position: bars.Position,
    content: bars.Content,
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
    sidebar_width: u16 = frontend_ui.sidebar.default_width,
    configuration_generation: u64 = 0,
    bars: bars.Layout = .{},
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
    proxy_status_revision_before: u64,
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

    pub fn append(changes: *AgentStatusChanges, change: AgentStatusChange) void {
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
    agent_revision_before: u64,
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
    key_lease: schema.PaneId,
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
    workspace_revision: u64,
    tabs_revision: u64,
    active_tab_revision: u64,
    panes_revision: u64,
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
    title,
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
    title: struct {
        pane_id: schema.PaneId,
        /// Borrowed only for the synchronous transition; empty clears it.
        title: []const u8,
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

pub const CopyModeFrame = struct {
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
    area: ui.Rect,
    disposition: PaneSplitDisposition,
    change: Change,
    layout_revision: u64,
    workspace_revision: u64,
    tabs_revision: u64,
    active_tab_revision: u64,
    panes_revision: u64,
};

pub const PaneSplitCommitState = struct {
    disposition: PaneSplitDisposition,
    change: Change,
    layout_revision: u64,
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
    layout_revision: u64,
    workspace_revision: u64,
    tabs_revision: u64,
    active_tab_revision: u64,
    panes_revision: u64,
};

pub const StalePaneExit = struct {
    pane_id: schema.PaneId,
    workspace_revision: u64,
    tabs_revision: u64,
    active_tab_revision: u64,
    panes_revision: u64,
};

pub const PaneExit = union(enum) {
    retired: PaneRetirement,
    stale: StalePaneExit,
};

pub const RemoveTab = struct {
    location: schema.TabLocation,
    workspace_removed: bool,
};

pub const RemovedPanes = struct {
    items: [schema.max_panes_per_tab]schema.PaneId = undefined,
    count: u8 = 0,

    pub fn append(panes: *RemovedPanes, pane_id: schema.PaneId) void {
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
    active_layout_revision: u64,
    active_tab_revision_before: u64,
    workspace_revision: u64,
    tabs_revision: u64,
    active_tab_revision: u64,
    panes_revision: u64,
    copy_revision: u64,
};

pub const TabRemovalAbsence = enum {
    workspace,
    tab,
};

pub const StaleTabRemoval = struct {
    location: schema.TabLocation,
    absence: TabRemovalAbsence,
    workspace_revision: u64,
    tabs_revision: u64,
    active_tab_revision: u64,
    panes_revision: u64,
    copy_revision: u64,
};

pub const TabRemovalCommit = union(enum) {
    removed: TabRemoval,
    stale: StaleTabRemoval,
};

pub const TabReconciliation = struct {
    location: schema.TabLocation,
    area: ui.Rect,
    removed_panes: RemovedPanes = .{},
    active: bool,
    panes_changed: bool,
    snapshot_loaded: bool = false,
    layout_revision: u64 = 0,
    workspace_revision: u64 = 0,
    tabs_revision: u64 = 0,
    active_tab_revision: u64 = 0,
    panes_revision: u64 = 0,
};

pub const WorkspaceTabInput = tabs_mod.WorkspaceTabInput;
pub const WorkspaceSnapshot = tabs_mod.WorkspaceSnapshotInput;
pub const TabSnapshot = tabs_mod.PaneSnapshot;

pub const RemovedWorkspaceTabs = struct {
    items: [schema.max_tabs_per_workspace]schema.TabLocation = undefined,
    count: u8 = 0,

    pub fn append(tabs: *RemovedWorkspaceTabs, location: schema.TabLocation) void {
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

    pub fn append(panes: *RemovedWorkspacePanes, pane_id: schema.PaneId) void {
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
    active_snapshot_loaded: bool = false,
    workspace_revision: u64 = 0,
    tabs_revision: u64 = 0,
    active_tab_revision: u64 = 0,
    panes_revision: u64 = 0,
};
