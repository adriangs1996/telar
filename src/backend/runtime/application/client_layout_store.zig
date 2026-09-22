//! Bounded, runtime-lifetime retention of layouts for reconnecting terminals.

const core = @import("telar-core");
const Record = @import("Record.zig");
const Sources = @import("Sources.zig");
const std = @import("std");

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

pub fn findTab(record: *const Record, location: core.TabLocation) ?usize {
    for (record.tabs[0..record.tab_count], 0..) |tab, index| {
        if (std.meta.eql(tab.location, location)) {
            return index;
        }
    }

    return null;
}

pub fn clearWorkspaceActive(record: *Record, workspace: core.WorkspaceLocation) void {
    for (record.tabs[0..record.tab_count]) |*tab| {
        if (std.meta.eql(tab.location.workspace, workspace)) {
            tab.workspace_active = false;
        }
    }
}

pub fn tabIsCurrent(tab: core.ClientTabLayoutView, sources: Sources) bool {
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

pub fn typedTabIsCurrent(tab: core.ClientTabLayout, sources: Sources) bool {
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
