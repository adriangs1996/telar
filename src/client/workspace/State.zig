const State = @This();
const Region = @import("Region.zig");
const ui = @import("telar-core").ui;
const std = @import("std");
current: Region = .{ .area = .{}, .revision = 0 },

/// Publishes a region only when its geometry changes. No storage is borrowed.
/// Example: `geometry.update(workbench);`.
pub fn update(state: *State, area: ui.Rect) void {
    if (std.meta.eql(state.current.area, area)) {
        return;
    }

    state.current = .{ .area = area, .revision = state.current.revision +% 1 };
}
