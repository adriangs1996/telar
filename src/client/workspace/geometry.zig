//! Geometry supplied by presentation, in pane-grid coordinates. Host pixels
//! are translated before entering application handlers.

const std = @import("std");
const ui = @import("telar-core").ui;

pub const Region = struct {
    area: ui.Rect,
    revision: u64,

    /// Rejects input captured before a host-region change, including ABA.
    /// Example: `if (!captured.matches(current)) return;`.
    pub fn matches(captured: Region, current: Region) bool {
        return captured.revision == current.revision and std.meta.eql(captured.area, current.area);
    }
};

pub const State = struct {
    current: Region = .{ .area = .{}, .revision = 0 },

    /// Publishes a region only when its geometry changes. No storage is borrowed.
    /// Example: `geometry.update(workbench);`.
    pub fn update(state: *State, area: ui.Rect) void {
        if (std.meta.eql(state.current.area, area)) {
            return;
        }

        state.current = .{ .area = area, .revision = state.current.revision +% 1 };
    }
};

test "geometry changes invalidate captured input even when the area returns" {
    var state: State = .{};
    const area: ui.Rect = .{ .x = 2, .y = 1, .w = 80, .h = 24 };
    state.update(area);
    const captured = state.current;
    state.update(area);
    try std.testing.expect(captured.matches(state.current));
    state.update(.{ .w = 10, .h = 10 });
    try std.testing.expect(!captured.matches(state.current));
    state.update(area);
    try std.testing.expect(!captured.matches(state.current));
}
