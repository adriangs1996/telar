//! One tab gesture; adapters supply points in units of their drag threshold.
const data = @import("model");
const std = @import("std");
const core = @import("telar-core");
const TabMoveIntent = @import("TabMoveIntent.zig");
const TabDrag = @This();

captured: bool = false,
source: ?core.TabLocation = null,
origin: [2]f64 = .{ 0, 0 },
dragging: bool = false,
destination: ?core.TabMoveTarget = null,

/// Example: `drag.begin(location, point);`
pub fn begin(self: *TabDrag, source: core.TabLocation, point: [2]f64) void {
    self.* = .{ .captured = true, .source = source, .origin = point };
}

/// A cancelled gesture remains a sink until its matching release.
/// Example: `drag.cancel();`
pub fn cancel(self: *TabDrag) void {
    self.source = null;
    self.destination = null;
    self.dragging = false;
}

/// Source identity survives focus changes, but never workspace replacement.
/// Example: `drag.validate(&client.model);`
pub fn validate(self: *TabDrag, model: *const data.ClientModel) void {
    const source = self.source orelse return;
    if (model.name_prompt.active() or !std.meta.eql(model.workspace, @as(?core.WorkspaceLocation, source.workspace)) or model.tabs.find(source.tab_id) == null) {
        self.cancel();
    }
}

/// Example: `drag.update(point, .{ .relative_to = tab_id, .direction = .next });`
pub fn update(self: *TabDrag, point: [2]f64, destination: ?core.TabMoveTarget) void {
    const source = self.source orelse return;
    self.dragging = self.dragging or @abs(point[0] - self.origin[0]) >= 1 or @abs(point[1] - self.origin[1]) >= 1;
    self.destination = if (self.dragging and destination != null and destination.?.relative_to != source.tab_id) destination else null;
}

/// Produces a single canonical move request on a valid drop.
/// Example: `const move = drag.finish() orelse return;`
pub fn finish(self: *TabDrag) ?TabMoveIntent {
    defer self.* = .{};
    const source = self.source orelse return null;
    const target = self.destination orelse return null;
    return .{ .location = source, .direction = target.direction, .relative_to = target.relative_to };
}
