//! Bounded, runtime-lifetime retention of layouts for reconnecting terminals.

const std = @import("std");
const core = @import("telar-core");
const pane_mod = @import("../../pane/root.zig");
const workspace_mod = @import("../../workspace/root.zig");

pub const schema = core.schema;
pub const PaneStore = pane_mod.PaneStore;

pub const Sources = @import("Sources.zig");

pub const Update = @import("Update.zig");

pub const SnapshotQuery = @import("SnapshotQuery.zig");

pub const SnapshotStorage = @import("SnapshotStorage.zig");

const StoredTab = @import("StoredTab.zig");

const Record = @import("Record.zig");

pub const Store = @import("Store.zig");

pub fn prune(record: *Record, sources: Sources) void {
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

pub fn findTab(record: *const Record, location: schema.TabLocation) ?usize {
    for (record.tabs[0..record.tab_count], 0..) |tab, index| {
        if (std.meta.eql(tab.location, location)) {
            return index;
        }
    }

    return null;
}

pub fn clearWorkspaceActive(record: *Record, workspace: schema.WorkspaceLocation) void {
    for (record.tabs[0..record.tab_count]) |*tab| {
        if (std.meta.eql(tab.location.workspace, workspace)) {
            tab.workspace_active = false;
        }
    }
}

pub fn tabIsCurrent(tab: schema.ClientTabLayoutView, sources: Sources) bool {
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

pub fn typedTabIsCurrent(tab: schema.ClientTabLayout, sources: Sources) bool {
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
