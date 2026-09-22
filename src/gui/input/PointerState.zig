//! Native geometry admission plus independent bounded gesture owners.
const pointer_owner = @import("pointer_owner.zig");
const data = @import("model");
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Geometry = @import("PointerGeometry.zig");
const Sample = @import("PointerSample.zig");
const Event = @import("PointerEvent.zig");
const PointerState = @This();
const PointerHover = @import("PointerHover.zig");
const LinkGesture = @import("LinkGesture.zig");

geometry: Geometry = .{},
revision: u64 = 0,
gesture_revision: u64 = 0,
scroll_remainder: f64 = 0,
owners: [3]pointer_owner.Owner = @splat(.shared),
last: [3]data.Mouse = @splat(.{
    .x = 0,
    .y = 0,
    .kind = .release,
}),
hover: PointerHover = .{},
link_gesture: LinkGesture = .{},

/// Example: `pointer.configure(origin, size);`
pub fn configure(self: *PointerState, origin: [2]u32, size: core.TerminalSize) void {
    const candidate: Geometry = .{ .origin = origin, .size = size };
    if (!std.meta.eql(self.geometry, candidate)) {
        self.geometry = candidate;
        self.revision +%= 1;
        self.hover.dirty = true;
        self.link_gesture.cancel();
    }
}

/// Example: `const sample = pointer.sample(event);`
pub fn sample(self: *const PointerState, event: Event) Sample {
    return .{ .event = event, .geometry_revision = self.revision, .gesture_revision = self.gesture_revision };
}

/// Invalidates queued gesture starts while an ordered cancellation waits for
/// transport capacity. Example: `pointer.invalidateGestures();`
pub fn invalidateGestures(self: *PointerState) void {
    self.gesture_revision +%= 1;
}
