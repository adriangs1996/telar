//! A native link opens on release; dragging or changed identity cancels it.
const data = @import("model");
const client = @import("telar-client");
const Hit = @import("LinkHit.zig");
const Gesture = @This();

pressed: ?Hit = null,
version: data.Version = .{},

/// Acquires the complete gesture without dispatching an external operation.
/// Example: `gesture.begin(hit, app.model.version());`
pub fn begin(self: *Gesture, hit: Hit, version: data.Version) void {
    self.pressed = hit;
    self.version = version;
}

/// A release opens only the unchanged target. Cancellation never opens a URL.
/// Example: `const target = gesture.finish(current_hit, app.model.version());`
pub fn finish(self: *Gesture, current: ?Hit, version: data.Version) ?data.LinkTarget {
    self.validate(current, version);
    const pressed = self.pressed orelse return null;
    self.pressed = null;
    const released = current orelse return null;
    return if (pressed.eql(&released)) pressed.match.target else null;
}

/// Navigation or an intervening target change cancels, even if later restored.
/// Example: `gesture.validate(hover.link, app.model.version());`
pub fn validate(self: *Gesture, current: ?Hit, version: data.Version) void {
    const pressed = self.pressed orelse return;
    const same_context = self.version.workspace == version.workspace and self.version.active_tab == version.active_tab and
        self.version.tabs == version.tabs and self.version.panes == version.panes and self.version.host == version.host and
        self.version.configuration == version.configuration and self.version.viewport == version.viewport;
    const same_target = if (current) |hit| pressed.eql(&hit) else false;
    if (!same_context or !same_target) {
        self.cancel();
    }
}

pub fn cancel(self: *Gesture) void {
    self.pressed = null;
}
