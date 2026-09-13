//! A native link opens on release; dragging or changed identity cancels it.
const client = @import("telar-client");
const Hit = @import("LinkHit.zig");
const Gesture = @This();

pressed: ?Hit = null,

/// Acquires the complete gesture without dispatching an external operation.
/// Example: `gesture.begin(hit);`
pub fn begin(gesture: *Gesture, hit: Hit) void {
    gesture.pressed = hit;
}

/// A release opens only the unchanged target. Cancellation never opens a URL.
/// Example: `const target = gesture.finish(current_hit);`
pub fn finish(gesture: *Gesture, current: ?Hit) ?client.LinkTarget {
    const pressed = gesture.pressed orelse return null;
    gesture.pressed = null;
    const released = current orelse return null;
    return if (pressed.eql(&released)) pressed.match.target else null;
}

pub fn cancel(gesture: *Gesture) void {
    gesture.pressed = null;
}
