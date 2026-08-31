//! Passive state owned by one disposable client.

const std = @import("std");
const core = @import("telar-core");
const agents = @import("../agents/root.zig");
const input_capability = @import("../input/root.zig");
const notifications = @import("../notifications/root.zig");
const name_prompt = @import("name_prompt.zig");
const workspace_capability = @import("../workspace/root.zig");

const copy_mode = input_capability.copy_mode;
const keybind = input_capability.keybind;
const schema = core.schema;
const layout_mod = workspace_capability.layout;
const multiplexer = workspace_capability.multiplexer;
const tabs_mod = workspace_capability.tabs;
const workspace_list_mod = workspace_capability.workspace_list;
const ui = core.ui;

pub const Version = struct {
    workspace: u64 = 0,
    workspace_list: u64 = 0,
    agents: u64 = 0,
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

pub const PaneInputTarget = union(enum) {
    focused,
    pane: schema.PaneId,
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
    workspace_list_snapshot: workspace_list_mod.Snapshot = .{},
    workspace_list_revision: u64 = 0,
    agent_snapshot: agents.Snapshot = .{},
    agent_revision: u64 = 0,
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
        var workspace = tabs_mod.Model.init(gpa);
        workspace.setPaneGaps(pane_gaps);

        return .{ .workspace = workspace };
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
            .workspace_list = model.workspace_list_revision,
            .agents = model.agent_revision,
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
    /// if (model.hasWorkingAgent()) scheduleTick();
    /// ```
    pub fn hasWorkingAgent(model: *const Model) bool {
        return model.agent_snapshot.hasWorkingAgent();
    }

    /// Resolves a sidebar identity into local focus or a runtime handoff
    /// without exposing agent replica storage to the input adapter.
    ///
    /// ```zig
    /// const plan = model.planAgentNavigation(key) orelse return;
    /// ```
    pub fn planAgentNavigation(model: *Model, key: agents.AgentKey) ?AgentNavigationPlan {
        const agent = model.agent_snapshot.find(key) orelse return null;
        if (model.workspace.tabForPane(key.pane_id)) |tab| {
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

    /// Resolves one user-input target without exposing pane storage. Prompts
    /// and copy mode retain exclusive ownership of pane input while active.
    ///
    /// ```zig
    /// const plan = model.planPaneInput(.focused) orelse return;
    /// ```
    pub fn planPaneInput(model: *const Model, target: PaneInputTarget) ?PaneInputPlan {
        if (model.name_prompt.active() or model.copy_state != null) {
            return null;
        }

        const active = model.workspace.activeConst() orelse return null;
        const pane = switch (target) {
            .focused => active.model.focusedPaneConst() orelse return null,
            .pane => |pane_id| active.model.findConst(pane_id) orelse return null,
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

    /// Returns the immutable copy-mode projection consumed by presenters.
    ///
    /// ```zig
    /// const projection = model.copyModeProjection() orelse return;
    /// ```
    pub fn copyModeProjection(model: *const Model) ?CopyModeProjection {
        const state = model.copy_state orelse return null;

        return .{ .pane_id = state.pane_id, .view = state.view() };
    }

    /// Enters copy mode on the attached focused pane. An active prompt,
    /// missing pane or repeated request leaves the copy revision intact.
    ///
    /// ```zig
    /// if (model.enterCopyMode()) observe(model.version());
    /// ```
    pub fn enterCopyMode(model: *Model) bool {
        if (model.copy_state != null or model.name_prompt.active()) {
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
    pub fn reconcileWorkspace(model: *Model, snapshot: schema.WorkspaceSnapshotView) !WorkspaceReconciliation {
        const current_workspace = model.workspace.workspace orelse return error.UnexpectedWorkspace;
        if (!std.meta.eql(current_workspace, snapshot.workspace)) {
            return error.UnexpectedWorkspace;
        }

        if (snapshot.tab_count == 0) {
            return error.WorkspaceHasNoTabs;
        }

        const snapshot_tab_count: usize = snapshot.tab_count;
        if (snapshot_tab_count > tabs_mod.max_tabs) {
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
            .tabs_changed = snapshot_tab_count != model.workspace.count,
        };
        var canonical_tabs: [tabs_mod.max_tabs]schema.TabId = undefined;
        var canonical_count: usize = 0;
        var iterator = snapshot.tabs();
        while (try iterator.next()) |descriptor| {
            canonical_tabs[canonical_count] = descriptor.tab_id;
            if (canonical_count >= model.workspace.count) {
                reconciliation.tabs_changed = true;
            } else {
                const current = &model.workspace.items[canonical_count].?;
                if (current.location.tab_id != descriptor.tab_id or
                    !std.mem.eql(u8, current.labelSlice(), descriptor.label))
                {
                    reconciliation.tabs_changed = true;
                }
            }

            canonical_count += 1;
        }

        var tabs = model.workspace.tabIterator();
        while (tabs.next()) |tab| {
            if (std.mem.findScalar(schema.TabId, canonical_tabs[0..canonical_count], tab.location.tab_id) != null) {
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

fn testingWorkspaceSnapshot(buffer: []u8, snapshot: schema.WorkspaceSnapshot) !schema.WorkspaceSnapshotView {
    return (try schema.decodeServer(try schema.encodeWorkspaceSnapshot(buffer, snapshot))).workspace_snapshot;
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

    try std.testing.expect(model.enterCopyMode());

    try std.testing.expect(model.copyModeActive());
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
    var buffer: [1024]u8 = undefined;

    const named = try testingWorkspaceSnapshot(&buffer, .{
        .request_id = @enumFromInt(1),
        .workspace = workspace,
        .name = "project",
        .tabs = &.{
            .{ .tab_id = first.tab_id, .position = 0, .pane_count = 1, .label = "main" },
            .{ .tab_id = second.tab_id, .position = 1, .pane_count = 1, .label = "logs" },
        },
    });
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

    const reordered = try testingWorkspaceSnapshot(&buffer, .{
        .request_id = @enumFromInt(2),
        .workspace = workspace,
        .name = "project",
        .tabs = &.{
            .{ .tab_id = second.tab_id, .position = 0, .pane_count = 1, .label = "server" },
            .{ .tab_id = first.tab_id, .position = 1, .pane_count = 1, .label = "main" },
        },
    });
    const tabs_change = try model.reconcileWorkspace(reordered);

    try std.testing.expect(!tabs_change.workspace_changed);
    try std.testing.expect(tabs_change.tabs_changed);
    try std.testing.expect(!tabs_change.active_tab_changed);
    try std.testing.expectEqualDeep(second, model.activeTabLocation().?);
    try std.testing.expectEqualStrings("server", model.workspace.items[0].?.labelSlice());
    try std.testing.expectEqualDeep(Version{ .workspace = 1, .tabs = 1 }, model.version());

    const removed = try testingWorkspaceSnapshot(&buffer, .{
        .request_id = @enumFromInt(3),
        .workspace = workspace,
        .name = "project",
        .tabs = &.{
            .{ .tab_id = first.tab_id, .position = 0, .pane_count = 1, .label = "main" },
        },
    });
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
    var buffer: [512]u8 = undefined;
    const empty = try testingWorkspaceSnapshot(&buffer, .{
        .request_id = @enumFromInt(1),
        .workspace = workspace,
        .name = "project",
        .tabs = &.{},
    });

    try std.testing.expectError(error.WorkspaceHasNoTabs, model.reconcileWorkspace(empty));

    try std.testing.expectEqualDeep(location, model.activeTabLocation().?);
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
    try std.testing.expect(model.hasWorkingAgent());

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
    try std.testing.expect(!model.hasWorkingAgent());
    try std.testing.expect((try model.reconcileAgentSnapshot(.{
        .revision = 5,
        .agents = &.{agent},
    })) == null);
    try std.testing.expectEqual(Version{ .agents = 2 }, model.version());
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
