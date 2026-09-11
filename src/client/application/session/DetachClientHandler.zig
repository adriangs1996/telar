const DetachClientHandler = @This();
const client_model = @import("../../root.zig").model;
const Effects = @import("ClientDetachmentEffects.zig");
const source_namespace = @import("client_detachment.zig");
const std = @import("std");
model: *client_model.Model,
effects: Effects,

/// Captures every current tab in stable order before delivering its
/// retirement. A failure stops delivery without revisiting earlier tabs.
///
/// ```zig
/// try handler.execute();
/// ```
pub fn execute(handler: *DetachClientHandler) !void {
    var locations: [source_namespace.schema.max_tabs_per_workspace]source_namespace.schema.TabLocation = undefined;
    var location_count: usize = 0;
    var tabs = handler.model.workspace.tabIterator();
    while (tabs.next()) |tab| {
        std.debug.assert(location_count < locations.len);
        locations[location_count] = tab.location;
        location_count += 1;
    }

    for (locations[0..location_count]) |location| {
        try handler.effects.detach_tab(handler.effects.context, location);
    }
}
