//! Passive semantic state owned by one disposable client.

const std = @import("std");
const core = @import("telar-core");
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
};

pub const Change = enum {
    unchanged,
    changed,
};

pub const TabSelection = struct {
    previous: schema.TabLocation,
    selected: schema.TabLocation,
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

pub const PaneAttachment = struct {
    pane_id: schema.PaneId,
    location: schema.TabLocation,
};

pub const PaneAttachmentConfirmation = enum {
    confirmed,
    stale,
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

pub const CloseTab = struct {
    location: schema.TabLocation,
    workspace_closed: bool,
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
    workspace_closed: bool,
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
    workspace_revision: u64 = 0,
    tabs_revision: u64 = 0,
    active_tab_revision: u64 = 0,
    panes_revision: u64 = 0,

    /// Creates the semantic model with the configured pane appearance.
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
    /// const removal = try model.closeTab(command) orelse return;
    /// ```
    pub fn closeTab(model: *Model, command: CloseTab) !?TabRemoval {
        const workspace = model.workspace.workspace orelse return null;
        if (!std.meta.eql(workspace, command.location.workspace)) {
            return error.UnexpectedWorkspace;
        }

        const closing = model.workspace.find(command.location.tab_id) orelse return null;
        if (!std.meta.eql(closing.location, command.location)) {
            return error.UnexpectedTab;
        }

        const workspace_closed = model.workspace.count == 1;
        if (workspace_closed != command.workspace_closed) {
            return error.UnexpectedWorkspaceClosure;
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
            .workspace_closed = workspace_closed,
        };
    }

    /// Selects one existing tab and returns the committed identity change.
    ///
    /// ```zig
    /// const selection = try model.selectTab(tab_id) orelse return;
    /// ```
    pub fn selectTab(model: *Model, tab_id: schema.TabId) !?TabSelection {
        const previous = model.workspace.activeConst() orelse return error.NoActiveTab;
        const selected_index = model.workspace.indexOf(tab_id) orelse return error.TabNotFound;
        if (selected_index == model.workspace.active_index) {
            return null;
        }

        const selection: TabSelection = .{
            .previous = previous.location,
            .selected = model.workspace.items[selected_index].?.location,
        };
        std.debug.assert(model.workspace.select(tab_id));
        model.active_tab_revision +%= 1;

        return selection;
    }
};

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

    const removal = (try model.closeTab(.{
        .location = first,
        .workspace_closed = false,
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

    const removal = (try model.closeTab(.{
        .location = second,
        .workspace_closed = false,
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

    try std.testing.expectError(error.UnexpectedWorkspaceClosure, model.closeTab(.{
        .location = location,
        .workspace_closed = false,
    }));
    try std.testing.expectEqual(@as(usize, 1), model.workspace.count);
    try std.testing.expectEqualDeep(Version{}, model.version());

    const removal = (try model.closeTab(.{
        .location = location,
        .workspace_closed = true,
    })).?;

    try std.testing.expect(removal.workspace_closed);
    try std.testing.expect(removal.was_active);
    try std.testing.expect(removal.active == null);
    try std.testing.expectEqual(@as(usize, 0), model.workspace.count);
    try std.testing.expectEqual(@as(u64, 1), model.version().tabs);
    try std.testing.expectEqual(@as(u64, 1), model.version().active_tab);
}

test "tab selection advances only the active identity revision" {
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

    const selection = (try model.selectTab(second.tab_id)).?;

    try std.testing.expectEqualDeep(first, selection.previous);
    try std.testing.expectEqualDeep(second, selection.selected);
    try std.testing.expectEqualDeep(second, model.activeTabLocation().?);
    try std.testing.expectEqual(@as(u64, 0), model.version().tabs);
    try std.testing.expectEqual(@as(u64, 1), model.version().active_tab);

    try std.testing.expect((try model.selectTab(second.tab_id)) == null);
    try std.testing.expectError(error.TabNotFound, model.selectTab(@enumFromInt(9)));
    try std.testing.expectEqual(@as(u64, 1), model.version().active_tab);
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
