const Region = @import("Region.zig");
const RectType = @import("telar-core").Rect;
const std = @import("std");
const State = @This();

current: Region = .{ .area = .{}, .revision = 0 },

/// Publishes a region only when its geometry changes. No storage is borrowed.
/// Example: `geometry.update(workbench);`.
pub fn update(state: *State, area: RectType) void {
    if (std.meta.eql(state.current.area, area)) {
        return;
    }

    state.current = .{ .area = area, .revision = state.current.revision +% 1 };
}
