const ClientLayoutCollection = @This();
const source_namespace = @import("layout.zig");
const ClientLayoutEntry = @import("ClientLayoutEntry.zig");
const std = @import("std");
locations: [source_namespace.max_client_layout_tabs]source_namespace.TabLocation = undefined,
workspace_active: [source_namespace.max_client_layout_tabs]bool = undefined,
count: usize = 0,
node_count: usize = 0,

pub fn append(collection: *ClientLayoutCollection, entry: ClientLayoutEntry) !void {
    for (collection.locations[0..collection.count]) |previous| {
        if (std.meta.eql(previous, entry.location)) {
            return error.DuplicateClientLayoutTab;
        }
    }
    for (collection.locations[0..collection.count], collection.workspace_active[0..collection.count]) |previous, previous_active| {
        if (previous_active and entry.workspace_active and std.meta.eql(previous.workspace, entry.location.workspace)) {
            return error.DuplicateClientLayoutWorkspace;
        }
    }

    collection.node_count = std.math.add(usize, collection.node_count, entry.node_count) catch
        return error.TooManyClientLayoutNodes;
    if (collection.node_count > source_namespace.max_client_layout_nodes) {
        return error.TooManyClientLayoutNodes;
    }

    collection.locations[collection.count] = entry.location;
    collection.workspace_active[collection.count] = entry.workspace_active;
    collection.count += 1;
}

pub fn validateActive(collection: *const ClientLayoutCollection, active: source_namespace.TabLocation) !void {
    for (collection.locations[0..collection.count], collection.workspace_active[0..collection.count]) |location, is_workspace_active| {
        if (std.meta.eql(location, active)) {
            if (!is_workspace_active) {
                return error.InvalidClientLayoutActiveTab;
            }

            return;
        }
    }

    return error.InvalidClientLayoutActiveTab;
}
