const ModelType = @import("../../model/Model.zig");
const ClientDetachmentEffects = @import("ClientDetachmentEffects.zig");
const max_tabs_per_workspace_module = @import("telar-core").max_tabs_per_workspace;
const TabLocationType = @import("telar-core").TabLocation;
const std = @import("std");
const DetachClientHandler = @This();

model: *ModelType,
effects: ClientDetachmentEffects,

/// Captures every current tab in stable order before delivering its
/// retirement. A failure stops delivery without revisiting earlier tabs.
///
/// ```zig
/// try handler.execute();
/// ```
pub fn execute(handler: *DetachClientHandler) !void {
    var locations: [max_tabs_per_workspace_module]TabLocationType = undefined;
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
