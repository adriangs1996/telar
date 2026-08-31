//! Passive state owned by one disposable client.

const std = @import("std");
const core = @import("telar-core");
const name_prompt = @import("name_prompt.zig");
const workspace_capability = @import("../workspace/root.zig");

const schema = core.schema;
const layout_mod = workspace_capability.layout;
const multiplexer = workspace_capability.multiplexer;
const tabs_mod = workspace_capability.tabs;
const ui = core.ui;

pub const Version = struct {
    workspace: u64 = 0,
    tabs: u64 = 0,
    active_tab: u64 = 0,
    panes: u64 = 0,
    chrome: u64 = 0,
    prompt: u64 = 0,
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
    tabs_revision: u64 = 0,
    active_tab_revision: u64 = 0,
    panes_revision: u64 = 0,
    sidebar_visible: bool = true,
    workspace_list_collapsed: bool = false,
    chrome_revision: u64 = 0,

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
            .tabs = model.tabs_revision,
            .active_tab = model.active_tab_revision,
            .panes = model.panes_revision,
            .chrome = model.chrome_revision,
            .prompt = model.name_prompt.version(),
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

        return reconciliation;
    }

    /// Commits one canonical pane list while preserving retained pane state.
    /// Only visible active-tab changes advance the pane revision.
    ///
    /// ```zig
    /// const reconciliation = try model.reconcileTab(snapshot, workbench);
    /// ```
    pub fn reconcileTab(model: *Model, snapshot: schema.TabSnapshotView, area: ui.Rect) !TabReconciliation {
        const tab = model.workspace.find(snapshot.location.tab_id) orelse return error.UnexpectedTab;
        if (!std.meta.eql(tab.location, snapshot.location)) {
            return error.UnexpectedTab;
        }

        if (snapshot.pane_count > schema.max_panes_per_tab) {
            return error.TooManyPanes;
        }

        var canonical_panes: [schema.max_panes_per_tab]schema.PaneId = undefined;
        var canonical_count: usize = 0;
        var descriptors = snapshot.panes();
        while (try descriptors.next()) |descriptor| {
            if (std.mem.findScalar(schema.PaneId, canonical_panes[0..canonical_count], descriptor.pane_id) != null) {
                return error.DuplicatePane;
            }

            const existing = model.workspace.findPane(descriptor.pane_id);
            if (existing != null and !std.meta.eql(existing.?.location, snapshot.location)) {
                return error.PaneAlreadyExists;
            }

            canonical_panes[canonical_count] = descriptor.pane_id;
            canonical_count += 1;
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
            if (std.mem.findScalar(schema.PaneId, canonical_panes[0..canonical_count], pane.id) == null) {
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

        return selection;
    }
};

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

fn testingTabSnapshot(buffer: []u8, snapshot: schema.TabSnapshot) !schema.TabSnapshotView {
    return (try schema.decodeServer(try schema.encodeTabSnapshot(buffer, snapshot))).tab_snapshot;
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

    var buffer: [256]u8 = undefined;
    const snapshot = try testingTabSnapshot(&buffer, .{
        .request_id = @enumFromInt(1),
        .location = location,
        .panes = &.{
            .{ .pane_id = left, .lifecycle = .running },
            .{ .pane_id = focused, .lifecycle = .running },
        },
    });
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
    var buffer: [256]u8 = undefined;
    const discovered = try testingTabSnapshot(&buffer, .{
        .request_id = @enumFromInt(1),
        .location = location,
        .panes = &.{
            .{ .pane_id = first, .lifecycle = .running },
            .{ .pane_id = second, .lifecycle = .running },
        },
    });

    const addition = try model.reconcileTab(discovered, .{ .w = 40, .h = 10 });

    try std.testing.expect(addition.active);
    try std.testing.expect(addition.panes_changed);
    try std.testing.expectEqual(@as(usize, 0), addition.removed_panes.slice().len);
    try std.testing.expect(model.workspace.findPane(second) != null);
    try std.testing.expectEqualDeep(Version{ .panes = 1 }, model.version());

    const unchanged = try model.reconcileTab(discovered, .{ .w = 40, .h = 10 });

    try std.testing.expect(!unchanged.panes_changed);
    try std.testing.expectEqualDeep(Version{ .panes = 1 }, model.version());

    const removed = try testingTabSnapshot(&buffer, .{
        .request_id = @enumFromInt(2),
        .location = location,
        .panes = &.{.{ .pane_id = second, .lifecycle = .running }},
    });
    const removal = try model.reconcileTab(removed, .{ .w = 40, .h = 10 });

    try std.testing.expect(removal.panes_changed);
    try std.testing.expectEqualSlices(schema.PaneId, &.{first}, removal.removed_panes.slice());
    try std.testing.expect(model.workspace.findPane(first) == null);
    try std.testing.expectEqualDeep(Version{ .panes = 2 }, model.version());
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
    var buffer: [256]u8 = undefined;
    const snapshot = try testingTabSnapshot(&buffer, .{
        .request_id = @enumFromInt(1),
        .location = inactive,
        .panes = &.{
            .{ .pane_id = @enumFromInt(2), .lifecycle = .running },
            .{ .pane_id = @enumFromInt(3), .lifecycle = .running },
        },
    });

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
    var buffer: [256]u8 = undefined;
    const snapshot = try testingTabSnapshot(&buffer, .{
        .request_id = @enumFromInt(1),
        .location = first,
        .panes = &.{
            .{ .pane_id = @enumFromInt(1), .lifecycle = .running },
            .{ .pane_id = @enumFromInt(2), .lifecycle = .running },
        },
    });

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
