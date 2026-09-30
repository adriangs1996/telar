const core = @import("telar-core");
const std = @import("std");
const PaneStore = @import("../pane/PaneStore.zig");
const Workspaces = @import("../workspace/Workspaces.zig");
const LayoutSnapshotStorage = @import("LayoutSnapshotStorage.zig");
/// Layouts retained for reconnecting clients: one bounded record
/// per client identity, checked against runtime panes and workspaces before
/// it is stored and again before it is restored. The least recently used
/// record makes room for a new identity.
const ClientLayouts = @This();

const Sources = struct {
    panes: *const PaneStore,
    workspaces: *const Workspaces,
};

const Exported = struct {
    identity: core.ClientIdentity,
    last_used: u64,
    payload: []const u8,
};

/// One client identity's layout: the tabs of every workspace it visited,
/// whose split trees share one node pool in tab order.
const Record = struct {
    identity: core.ClientIdentity = .invalid,
    last_used: u64 = 0,
    sidebar_visible: bool = true,
    sidebar_width: u16 = 0,
    workspace_list_collapsed: bool = false,
    active_tab: core.TabLocation = undefined,
    tabs: [core.max_client_layout_tabs]StoredTab = undefined,
    tab_count: u16 = 0,
    nodes: [core.max_client_layout_nodes]core.ClientLayoutNode = undefined,
    node_count: u16 = 0,

    fn layoutAt(self: *const Record, index: usize) core.ClientTabLayout {
        const tab = &self.tabs[index];
        return .{
            .location = tab.location,
            .focused_pane = tab.focused_pane,
            .fullscreen = tab.fullscreen,
            .workspace_active = tab.workspace_active,
            .nodes = self.nodes[tab.node_start..][0..tab.node_count],
        };
    }

    /// Appends one current tab and its tree at the end of the pool.
    fn append(self: *Record, tab: core.ClientTabLayoutView) !void {
        if (self.tab_count == self.tabs.len or tab.node_count > self.nodes.len - self.node_count) {
            return error.TooManyClientLayoutNodes;
        }

        const start = self.node_count;
        var nodes = tab.nodes();
        var index: usize = start;
        while (try nodes.next()) |node| : (index += 1) {
            self.nodes[index] = node;
        }

        self.tabs[self.tab_count] = .{
            .location = tab.location,
            .focused_pane = tab.focused_pane,
            .fullscreen = tab.fullscreen,
            .workspace_active = tab.workspace_active,
            .node_start = start,
            .node_count = @intCast(tab.node_count),
        };
        self.tab_count += 1;
        self.node_count += @intCast(tab.node_count);
    }

    /// Removes the tab at `index` and closes the gap its tree left.
    fn remove(self: *Record, index: usize) void {
        const removed = self.tabs[index];
        const tail_start = removed.node_start + removed.node_count;
        std.mem.copyForwards(core.ClientLayoutNode, self.nodes[removed.node_start..], self.nodes[tail_start..self.node_count]);
        self.node_count -= removed.node_count;
        std.mem.copyForwards(StoredTab, self.tabs[index..], self.tabs[index + 1 .. self.tab_count]);
        self.tab_count -= 1;
        for (self.tabs[index..self.tab_count]) |*tab| {
            tab.node_start -= removed.node_count;
        }
    }
};

const StoredTab = struct {
    location: core.TabLocation,
    focused_pane: core.PaneId,
    fullscreen: bool,
    workspace_active: bool,
    node_start: u16,
    node_count: u16,
};

gpa: ?std.mem.Allocator = null,
records: []Record = &.{},
clock: u64 = 0,

/// Preallocates every bounded record before the runtime loop starts.
///
/// ```zig
/// var client_layouts = try ClientLayouts.init(gpa);
/// defer client_layouts.deinit();
/// ```
pub fn init(gpa: std.mem.Allocator) !ClientLayouts {
    const records = try gpa.alloc(Record, core.max_client_layout_clients);
    for (records) |*record| {
        record.* = .{};
    }

    return .{ .gpa = gpa, .records = records };
}

/// Releases the preallocated terminal-record array.
///
/// ```zig
/// client_layouts.deinit();
/// ```
pub fn deinit(self: *ClientLayouts) void {
    const gpa = self.gpa orelse return;
    gpa.free(self.records);
    self.* = .{};
}

/// Encodes the record at `index` as one `update_client_layout` request so
/// a checkpoint can replay it through `replace` on restore. Empty slots
/// yield null.
///
/// ```zig
/// var index: usize = 0;
/// while (index < client_layouts.capacity()) : (index += 1) {
///     const exported = try client_layouts.exportRecord(index, &buffer) orelse continue;
/// }
/// ```
pub fn exportRecord(self: *const ClientLayouts, index: usize, buffer: []u8) !?Exported {
    const record = &self.records[index];
    if (record.identity == .invalid) {
        return null;
    }

    var tabs: [core.max_client_layout_tabs]core.ClientTabLayout = undefined;
    for (0..record.tab_count) |position| {
        tabs[position] = record.layoutAt(position);
    }

    return .{
        .identity = record.identity,
        .last_used = record.last_used,
        .payload = try core.encodeClientLayoutUpdate(buffer, .{
            .sidebar_visible = record.sidebar_visible,
            .sidebar_width = record.sidebar_width,
            .workspace_list_collapsed = record.workspace_list_collapsed,
            .active_tab = record.active_tab,
            .tabs = tabs[0..record.tab_count],
        }),
    };
}

/// The pane focused in the active tab of the layout `identity` last
/// reported, or null when no layout is retained for it.
///
/// ```zig
/// if (client_layouts.focusedPane(identity) == pane_id) refuse();
/// ```
pub fn focusedPane(self: *const ClientLayouts, identity: core.ClientIdentity) ?core.PaneId {
    if (identity == .invalid) {
        return null;
    }

    for (self.records) |*record| {
        if (record.identity != identity) {
            continue;
        }

        for (record.tabs[0..record.tab_count]) |*tab| {
            if (std.meta.eql(tab.location, record.active_tab)) {
                return tab.focused_pane;
            }
        }

        return null;
    }

    return null;
}

pub fn capacity(self: *const ClientLayouts) usize {
    return self.records.len;
}

/// Merges one terminal's current workspace into its retained snapshot
/// after checking every pane against authoritative runtime state.
///
/// ```zig
/// try client_layouts.replace(identity, layout, &model.panes, &model.workspaces);
/// ```
pub fn replace(self: *ClientLayouts, identity: core.ClientIdentity, layout: core.ClientLayoutUpdateView, panes: *const PaneStore, workspaces: *const Workspaces) !void {
    if (identity == .invalid) {
        return error.InvalidClientIdentity;
    }

    const sources: Sources = .{ .panes = panes, .workspaces = workspaces };

    var valid_count: usize = 0;
    var active_valid = false;
    var tabs = layout.tabs();
    while (try tabs.next()) |tab| {
        if (!tabIsCurrent(tab, sources)) {
            if (std.meta.eql(tab.location, layout.active_tab)) {
                return;
            }

            continue;
        }

        valid_count += 1;
        active_valid = active_valid or std.meta.eql(tab.location, layout.active_tab);
    }

    if (!active_valid or valid_count == 0) {
        return;
    }

    const record = try self.acquire(identity);
    prune(record, sources);
    record.sidebar_visible = layout.sidebar_visible;
    record.sidebar_width = layout.sidebar_width;
    record.workspace_list_collapsed = layout.workspace_list_collapsed;
    record.active_tab = layout.active_tab;
    tabs = layout.tabs();
    while (try tabs.next()) |tab| {
        if (!tabIsCurrent(tab, sources)) {
            continue;
        }

        if (tab.workspace_active) {
            clearWorkspaceActive(record, tab.location.workspace);
        }

        if (findTab(record, tab.location)) |index| {
            record.remove(index);
        }

        try record.append(tab);
    }
}

/// Returns a current runtime-filtered snapshot, or an explicit empty
/// result when this terminal has no safe state to restore.
///
/// ```zig
/// const snapshot = client_layouts.snapshot(identity, &model.panes, &model.workspaces, &storage);
/// ```
pub fn snapshot(self: *ClientLayouts, identity: core.ClientIdentity, panes: *const PaneStore, workspaces: *const Workspaces, storage: *LayoutSnapshotStorage) core.ClientLayoutSnapshot {
    const sources: Sources = .{ .panes = panes, .workspaces = workspaces };
    const record = self.find(identity) orelse return .{ .restored = false };
    self.touch(record);
    var tab_count: usize = 0;
    var active_valid = false;
    for (0..record.tab_count) |index| {
        const layout = record.layoutAt(index);
        if (!typedTabIsCurrent(layout, sources)) {
            continue;
        }

        storage.tabs[tab_count] = layout;
        tab_count += 1;
        active_valid = active_valid or std.meta.eql(layout.location, record.active_tab);
    }
    return .{
        .restored = true,
        .sidebar_visible = record.sidebar_visible,
        .sidebar_width = record.sidebar_width,
        .workspace_list_collapsed = record.workspace_list_collapsed,
        .active_tab = if (active_valid) record.active_tab else null,
        .tabs = storage.tabs[0..tab_count],
    };
}

fn acquire(self: *ClientLayouts, identity: core.ClientIdentity) !*Record {
    if (self.find(identity)) |record| {
        self.touch(record);
        return record;
    }

    if (self.gpa == null) {
        return error.ClientLayoutStoreUninitialized;
    }

    var selected: ?usize = null;
    var oldest: u64 = std.math.maxInt(u64);
    for (self.records, 0..) |*record, index| {
        if (record.identity == .invalid) {
            selected = index;
            break;
        }
        if (record.last_used < oldest) {
            oldest = record.last_used;
            selected = index;
        }
    }

    const index = selected orelse unreachable;
    const record = &self.records[index];
    record.* = .{
        .identity = identity,
    };
    self.touch(record);
    return record;
}

fn find(self: *ClientLayouts, identity: core.ClientIdentity) ?*Record {
    for (self.records) |*record| {
        if (record.identity == identity) {
            return record;
        }
    }

    return null;
}

fn touch(self: *ClientLayouts, record: *Record) void {
    self.clock +%= 1;
    if (self.clock == 0) {
        self.clock = 1;
    }

    record.last_used = self.clock;
}

fn prune(record: *Record, sources: Sources) void {
    var index: usize = 0;
    while (index < record.tab_count) {
        if (typedTabIsCurrent(record.layoutAt(index), sources)) {
            index += 1;
            continue;
        }

        record.remove(index);
    }
}

fn findTab(record: *const Record, location: core.TabLocation) ?usize {
    for (record.tabs[0..record.tab_count], 0..) |tab, index| {
        if (std.meta.eql(tab.location, location)) {
            return index;
        }
    }

    return null;
}

fn clearWorkspaceActive(record: *Record, workspace: core.WorkspaceLocation) void {
    for (record.tabs[0..record.tab_count]) |*tab| {
        if (std.meta.eql(tab.location.workspace, workspace)) {
            tab.workspace_active = false;
        }
    }
}

fn tabIsCurrent(tab: core.ClientTabLayoutView, sources: Sources) bool {
    var pane_ids: [core.max_panes_per_tab]core.PaneId = undefined;
    var pane_count: usize = 0;
    var nodes = tab.nodes();
    while (nodes.next() catch return false) |node| {
        if (node == .pane) {
            pane_ids[pane_count] = node.pane.id;
            pane_count += 1;
        }
    }

    return paneSetIsCurrent(tab.location, pane_ids[0..pane_count], sources);
}

fn typedTabIsCurrent(tab: core.ClientTabLayout, sources: Sources) bool {
    var pane_ids: [core.max_panes_per_tab]core.PaneId = undefined;
    var pane_count: usize = 0;
    for (tab.nodes) |node| {
        if (node == .pane) {
            pane_ids[pane_count] = node.pane.id;
            pane_count += 1;
        }
    }

    return paneSetIsCurrent(tab.location, pane_ids[0..pane_count], sources);
}

fn paneSetIsCurrent(location: core.TabLocation, pane_ids: []const core.PaneId, sources: Sources) bool {
    if (!sources.workspaces.contains(location)) {
        return false;
    }

    var descriptors: [core.max_panes_per_tab]core.PaneDescriptor = undefined;
    const current = sources.panes.descriptorsAt(location, &descriptors);
    if (current.len != pane_ids.len) {
        return false;
    }
    for (current) |descriptor| {
        if (std.mem.findScalar(core.PaneId, pane_ids, descriptor.pane_id) == null) {
            return false;
        }
    }

    return true;
}
