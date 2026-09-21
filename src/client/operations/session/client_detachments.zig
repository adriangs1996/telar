//! Detaches every runtime pane attachment owned by one client.

const Client = @import("../../AttachedClient.zig");
const std = @import("std");
const max_tabs = @import("telar-core").max_tabs_per_workspace;
const TabLocationType = @import("telar-core").TabLocation;
const tab_attachments = @import("../tabs/tab_attachments.zig");

/// Detaches every tab in stable client order before the event loop exits.
///
/// ```zig
/// try apply(client);
/// ```
pub fn apply(client: *Client) !void {
    var locations: [max_tabs]TabLocationType = undefined;
    var count: usize = 0;
    var tabs = client.model.workspace.tabIterator();
    while (tabs.next()) |tab| {
        std.debug.assert(count < locations.len);
        locations[count] = tab.location;
        count += 1;
    }

    for (locations[0..count]) |location| {
        try tab_attachments.detach(client, location);
    }
}
