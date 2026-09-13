//! A native link opens on release; dragging or changed identity cancels it.
const client = @import("telar-client");
const Hit = @import("LinkHit.zig");
const Gesture = @This();

pressed: ?Hit = null,
version: client.Version = .{},

/// Acquires the complete gesture without dispatching an external operation.
/// Example: `gesture.begin(hit);`
pub fn begin(gesture: *Gesture, hit: Hit, version: client.Version) void {
    gesture.pressed = hit;
    gesture.version = version;
}

/// A release opens only the unchanged target. Cancellation never opens a URL.
/// Example: `const target = gesture.finish(current_hit);`
pub fn finish(gesture: *Gesture, current: ?Hit, version: client.Version) ?client.LinkTarget {
    gesture.validate(current, version);
    const pressed = gesture.pressed orelse return null;
    gesture.pressed = null;
    const released = current orelse return null;
    return if (pressed.eql(&released)) pressed.match.target else null;
}

/// Navigation or an intervening target change cancels, even if later restored.
/// Example: `gesture.validate(hover.link, app.model.version());`
pub fn validate(gesture: *Gesture, current: ?Hit, version: client.Version) void {
    const pressed = gesture.pressed orelse return;
    const same_context = gesture.version.workspace == version.workspace and gesture.version.active_tab == version.active_tab and
        gesture.version.tabs == version.tabs and gesture.version.panes == version.panes and gesture.version.host == version.host and
        gesture.version.configuration == version.configuration and gesture.version.viewport == version.viewport;
    const same_target = if (current) |hit| pressed.eql(&hit) else false;
    if (!same_context or !same_target) {
        gesture.cancel();
    }
}

pub fn cancel(gesture: *Gesture) void {
    gesture.pressed = null;
}
