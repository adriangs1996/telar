//! One tab gesture; adapters supply points in units of their drag threshold.
const core = @import("telar-core");
const Model = @import("../../model/Model.zig");
const TabMoveIntent = @import("TabMoveIntent.zig");
const TabDrag = @This();

captured: bool = false,
source: ?core.TabLocation = null,
origin: [2]f64 = .{ 0, 0 },
dragging: bool = false,
destination: ?core.TabMoveTarget = null,

/// Example: `drag.begin(location, point);`
pub fn begin(drag: *TabDrag, source: core.TabLocation, point: [2]f64) void {
    drag.* = .{ .captured = true, .source = source, .origin = point };
}

/// A cancelled gesture remains a sink until its matching release.
/// Example: `drag.cancel();`
pub fn cancel(drag: *TabDrag) void {
    drag.source = null;
    drag.destination = null;
    drag.dragging = false;
}

/// Source identity survives focus changes, but never workspace replacement.
/// Example: `drag.validate(&client.model);`
pub fn validate(drag: *TabDrag, model: *const Model) void {
    const source = drag.source orelse return;
    if (model.name_prompt.active() or !@import("std").meta.eql(model.workspace.workspace, @as(?core.WorkspaceLocation, source.workspace)) or model.workspace.indexOf(source.tab_id) == null) {
        drag.cancel();
    }
}

/// Example: `drag.update(point, .{ .relative_to = tab_id, .direction = .next });`
pub fn update(drag: *TabDrag, point: [2]f64, destination: ?core.TabMoveTarget) void {
    const source = drag.source orelse return;
    drag.dragging = drag.dragging or @abs(point[0] - drag.origin[0]) >= 1 or @abs(point[1] - drag.origin[1]) >= 1;
    drag.destination = if (drag.dragging and destination != null and destination.?.relative_to != source.tab_id) destination else null;
}

/// Produces a single canonical move request on a valid drop.
/// Example: `const move = drag.finish() orelse return;`
pub fn finish(drag: *TabDrag) ?TabMoveIntent {
    defer drag.* = .{};
    const source = drag.source orelse return null;
    const target = drag.destination orelse return null;
    return .{ .location = source, .direction = target.direction, .relative_to = target.relative_to };
}
