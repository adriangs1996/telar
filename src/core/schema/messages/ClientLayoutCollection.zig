const types = @import("../types.zig");
const TabLocation = @import("../TabLocation.zig");
const std = @import("std");
const ClientLayoutCollection = @This();

locations: [types.max_client_layout_tabs]TabLocation = undefined,
workspace_active: [types.max_client_layout_tabs]bool = undefined,
count: usize = 0,
node_count: usize = 0,

pub fn append(self: *ClientLayoutCollection, entry: ClientLayoutEntry) !void {
    for (self.locations[0..self.count]) |previous| {
        if (std.meta.eql(previous, entry.location)) {
            return error.DuplicateClientLayoutTab;
        }
    }
    for (self.locations[0..self.count], self.workspace_active[0..self.count]) |previous, previous_active| {
        if (previous_active and entry.workspace_active and std.meta.eql(previous.workspace, entry.location.workspace)) {
            return error.DuplicateClientLayoutWorkspace;
        }
    }

    self.node_count = std.math.add(usize, self.node_count, entry.node_count) catch
        return error.TooManyClientLayoutNodes;
    if (self.node_count > types.max_client_layout_nodes) {
        return error.TooManyClientLayoutNodes;
    }

    self.locations[self.count] = entry.location;
    self.workspace_active[self.count] = entry.workspace_active;
    self.count += 1;
}

pub fn validateActive(self: *const ClientLayoutCollection, active: TabLocation) !void {
    for (self.locations[0..self.count], self.workspace_active[0..self.count]) |location, is_workspace_active| {
        if (std.meta.eql(location, active)) {
            if (!is_workspace_active) {
                return error.InvalidClientLayoutActiveTab;
            }

            return;
        }
    }

    return error.InvalidClientLayoutActiveTab;
}

const ClientLayoutEntry = struct {
    location: TabLocation,
    workspace_active: bool,
    node_count: usize,
};
