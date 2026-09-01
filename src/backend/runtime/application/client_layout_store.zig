//! Bounded, runtime-lifetime retention of layouts for reconnecting terminals.

const std = @import("std");
const core = @import("telar-core");
const pane_mod = @import("../../pane/root.zig");
const workspace_mod = @import("../../workspace/root.zig");

const schema = core.schema;
const PaneStore = pane_mod.PaneStore;

pub const Sources = struct {
    panes: *const PaneStore,
    workspaces: workspace_mod.Reader,
};

pub const Update = struct {
    identity: schema.ClientIdentity,
    layout: schema.ClientLayoutUpdateView,
    sources: Sources,
};

pub const SnapshotQuery = struct {
    identity: schema.ClientIdentity,
    sources: Sources,
};

pub const SnapshotStorage = struct {
    tabs: [schema.max_client_layout_tabs]schema.ClientTabLayout = undefined,
};

const StoredTab = struct {
    location: schema.TabLocation,
    focused_pane: schema.PaneId,
    fullscreen: bool,
    workspace_active: bool,
    nodes: [schema.max_client_layout_nodes]schema.ClientLayoutNode = undefined,
    node_count: u8,

    fn copy(tab: schema.ClientTabLayoutView) !StoredTab {
        var stored: StoredTab = .{
            .location = tab.location,
            .focused_pane = tab.focused_pane,
            .fullscreen = tab.fullscreen,
            .workspace_active = tab.workspace_active,
            .node_count = @intCast(tab.node_count),
        };
        var nodes = tab.nodes();
        var index: usize = 0;
        while (try nodes.next()) |node| : (index += 1) {
            stored.nodes[index] = node;
        }

        return stored;
    }

    fn schemaLayout(tab: *const StoredTab) schema.ClientTabLayout {
        return .{
            .location = tab.location,
            .focused_pane = tab.focused_pane,
            .fullscreen = tab.fullscreen,
            .workspace_active = tab.workspace_active,
            .nodes = tab.nodes[0..tab.node_count],
        };
    }
};

const Record = struct {
    identity: schema.ClientIdentity = .invalid,
    last_used: u64 = 0,
    sidebar_visible: bool = true,
    sidebar_width: u16 = 0,
    workspace_list_collapsed: bool = false,
    active_tab: schema.TabLocation = undefined,
    tabs: [schema.max_client_layout_tabs]StoredTab = undefined,
    tab_count: u8 = 0,
};

pub const Store = struct {
    gpa: ?std.mem.Allocator = null,
    records: []Record = &.{},
    clock: u64 = 0,

    /// Preallocates every bounded record before the runtime loop starts.
    ///
    /// ```zig
    /// var store = try Store.init(gpa);
    /// defer store.deinit();
    /// ```
    pub fn init(gpa: std.mem.Allocator) !Store {
        const records = try gpa.alloc(Record, schema.max_client_layout_clients);
        for (records) |*record| {
            record.* = .{};
        }

        return .{ .gpa = gpa, .records = records };
    }

    /// Releases the preallocated terminal-record array.
    ///
    /// ```zig
    /// store.deinit();
    /// ```
    pub fn deinit(store: *Store) void {
        const gpa = store.gpa orelse return;
        gpa.free(store.records);
        store.* = .{};
    }

    /// Merges one terminal's current workspace into its retained snapshot
    /// after checking every pane against authoritative runtime state.
    ///
    /// ```zig
    /// try store.replace(update);
    /// ```
    pub fn replace(store: *Store, update: Update) !void {
        if (update.identity == .invalid) {
            return error.InvalidClientIdentity;
        }

        var valid_count: usize = 0;
        var active_valid = false;
        var tabs = update.layout.tabs();
        while (try tabs.next()) |tab| {
            if (!tabIsCurrent(tab, update.sources)) {
                if (std.meta.eql(tab.location, update.layout.active_tab)) {
                    return;
                }

                continue;
            }

            valid_count += 1;
            active_valid = active_valid or std.meta.eql(tab.location, update.layout.active_tab);
        }

        if (!active_valid or valid_count == 0) {
            return;
        }

        const record = try store.acquire(update.identity);
        prune(record, update.sources);
        record.sidebar_visible = update.layout.sidebar_visible;
        record.sidebar_width = update.layout.sidebar_width;
        record.workspace_list_collapsed = update.layout.workspace_list_collapsed;
        record.active_tab = update.layout.active_tab;
        tabs = update.layout.tabs();
        while (try tabs.next()) |tab| {
            if (!tabIsCurrent(tab, update.sources)) {
                continue;
            }

            if (tab.workspace_active) {
                clearWorkspaceActive(record, tab.location.workspace);
            }

            const stored = try StoredTab.copy(tab);
            if (findTab(record, tab.location)) |index| {
                record.tabs[index] = stored;
            } else {
                std.debug.assert(record.tab_count < record.tabs.len);
                record.tabs[record.tab_count] = stored;
                record.tab_count += 1;
            }
        }
    }

    /// Returns a current runtime-filtered snapshot, or an explicit empty
    /// result when this terminal has no safe state to restore.
    ///
    /// ```zig
    /// const snapshot = store.snapshot(query, &storage);
    /// ```
    pub fn snapshot(store: *Store, query: SnapshotQuery, storage: *SnapshotStorage) schema.ClientLayoutSnapshot {
        const record = store.find(query.identity) orelse return .{ .restored = false };
        store.touch(record);
        var tab_count: usize = 0;
        var active_valid = false;
        for (record.tabs[0..record.tab_count]) |*tab| {
            const layout = tab.schemaLayout();
            if (!typedTabIsCurrent(layout, query.sources)) {
                continue;
            }

            storage.tabs[tab_count] = layout;
            tab_count += 1;
            active_valid = active_valid or std.meta.eql(tab.location, record.active_tab);
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

    fn acquire(store: *Store, identity: schema.ClientIdentity) !*Record {
        if (store.find(identity)) |record| {
            store.touch(record);
            return record;
        }

        if (store.gpa == null) {
            return error.ClientLayoutStoreUninitialized;
        }

        var selected: ?usize = null;
        var oldest: u64 = std.math.maxInt(u64);
        for (store.records, 0..) |*record, index| {
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
        const record = &store.records[index];
        record.* = .{
            .identity = identity,
        };
        store.touch(record);
        return record;
    }

    fn find(store: *Store, identity: schema.ClientIdentity) ?*Record {
        for (store.records) |*record| {
            if (record.identity == identity) {
                return record;
            }
        }

        return null;
    }

    fn touch(store: *Store, record: *Record) void {
        store.clock +%= 1;
        if (store.clock == 0) {
            store.clock = 1;
        }

        record.last_used = store.clock;
    }
};

fn prune(record: *Record, sources: Sources) void {
    var write_index: usize = 0;
    for (record.tabs[0..record.tab_count]) |tab| {
        if (!typedTabIsCurrent(tab.schemaLayout(), sources)) {
            continue;
        }

        record.tabs[write_index] = tab;
        write_index += 1;
    }

    record.tab_count = @intCast(write_index);
}

fn findTab(record: *const Record, location: schema.TabLocation) ?usize {
    for (record.tabs[0..record.tab_count], 0..) |tab, index| {
        if (std.meta.eql(tab.location, location)) {
            return index;
        }
    }

    return null;
}

fn clearWorkspaceActive(record: *Record, workspace: schema.WorkspaceLocation) void {
    for (record.tabs[0..record.tab_count]) |*tab| {
        if (std.meta.eql(tab.location.workspace, workspace)) {
            tab.workspace_active = false;
        }
    }
}

fn tabIsCurrent(tab: schema.ClientTabLayoutView, sources: Sources) bool {
    var pane_ids: [schema.max_panes_per_tab]schema.PaneId = undefined;
    var pane_count: usize = 0;
    var nodes = tab.nodes();
    while (nodes.next() catch return false) |node| {
        if (node == .pane) {
            pane_ids[pane_count] = node.pane;
            pane_count += 1;
        }
    }

    return paneSetIsCurrent(tab.location, pane_ids[0..pane_count], sources);
}

fn typedTabIsCurrent(tab: schema.ClientTabLayout, sources: Sources) bool {
    var pane_ids: [schema.max_panes_per_tab]schema.PaneId = undefined;
    var pane_count: usize = 0;
    for (tab.nodes) |node| {
        if (node == .pane) {
            pane_ids[pane_count] = node.pane;
            pane_count += 1;
        }
    }

    return paneSetIsCurrent(tab.location, pane_ids[0..pane_count], sources);
}

fn paneSetIsCurrent(location: schema.TabLocation, pane_ids: []const schema.PaneId, sources: Sources) bool {
    if (!sources.workspaces.contains(location)) {
        return false;
    }

    var descriptors: [schema.max_panes_per_tab]schema.PaneDescriptor = undefined;
    const current = sources.panes.descriptorsAt(location, &descriptors);
    if (current.len != pane_ids.len) {
        return false;
    }
    for (current) |descriptor| {
        if (std.mem.findScalar(schema.PaneId, pane_ids, descriptor.pane_id) == null) {
            return false;
        }
    }

    return true;
}
