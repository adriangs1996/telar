//! Bounded, runtime-lifetime retention of layouts for reconnecting terminals.

const Record = @import("Record.zig");
const Sources = @import("Sources.zig");
const TabLocationType = @import("telar-core").TabLocation;
const std = @import("std");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const ClientTabLayoutViewType = @import("telar-core").ClientTabLayoutView;
const max_panes_per_tab_module = @import("telar-core").max_panes_per_tab;
const PaneIdType = @import("telar-core").PaneId;
const ClientTabLayoutType = @import("telar-core").ClientTabLayout;
const PaneDescriptorType = @import("telar-core").PaneDescriptor;

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

pub fn findTab(record: *const Record, location: TabLocationType) ?usize {
    for (record.tabs[0..record.tab_count], 0..) |tab, index| {
        if (std.meta.eql(tab.location, location)) {
            return index;
        }
    }

    return null;
}

pub fn clearWorkspaceActive(record: *Record, workspace: WorkspaceLocationType) void {
    for (record.tabs[0..record.tab_count]) |*tab| {
        if (std.meta.eql(tab.location.workspace, workspace)) {
            tab.workspace_active = false;
        }
    }
}

pub fn tabIsCurrent(tab: ClientTabLayoutViewType, sources: Sources) bool {
    var pane_ids: [max_panes_per_tab_module]PaneIdType = undefined;
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

pub fn typedTabIsCurrent(tab: ClientTabLayoutType, sources: Sources) bool {
    var pane_ids: [max_panes_per_tab_module]PaneIdType = undefined;
    var pane_count: usize = 0;
    for (tab.nodes) |node| {
        if (node == .pane) {
            pane_ids[pane_count] = node.pane;
            pane_count += 1;
        }
    }

    return paneSetIsCurrent(tab.location, pane_ids[0..pane_count], sources);
}

fn paneSetIsCurrent(location: TabLocationType, pane_ids: []const PaneIdType, sources: Sources) bool {
    if (!sources.workspaces.contains(location)) {
        return false;
    }

    var descriptors: [max_panes_per_tab_module]PaneDescriptorType = undefined;
    const current = sources.panes.descriptorsAt(location, &descriptors);
    if (current.len != pane_ids.len) {
        return false;
    }
    for (current) |descriptor| {
        if (std.mem.findScalar(PaneIdType, pane_ids, descriptor.pane_id) == null) {
            return false;
        }
    }

    return true;
}
