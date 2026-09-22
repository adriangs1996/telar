const data = @import("model");
const core = @import("telar-core");
const std = @import("std");
const State = @This();

current: data.Region = .{ .area = .{}, .revision = 0 },

/// Publishes a region only when its geometry changes. No storage is borrowed.
/// Example: `geometry.update(workbench);`.
pub fn update(state: *State, area: core.Rect) void {
    if (std.meta.eql(state.current.area, area)) {
        return;
    }

    state.current = .{ .area = area, .revision = state.current.revision +% 1 };
}
