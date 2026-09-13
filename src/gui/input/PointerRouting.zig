//! Native geometry admission plus independent bounded gesture owners.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Geometry = @import("PointerGeometry.zig");
const Capture = @import("PointerCapture.zig");
const Sample = @import("PointerSample.zig");
const Event = @import("../native/InputEvent.zig").InputEvent;
const Routing = @This();

geometry: Geometry = .{},
revision: u64 = 0,
held: [3]?Capture = @splat(null),
owned: [3]bool = @splat(false),

/// Example: `pointer.configure(origin, size);`
pub fn configure(pointer: *Routing, origin: [2]u32, size: core.TerminalSize) void {
    const candidate: Geometry = .{ .origin = origin, .size = size };
    if (!std.meta.eql(pointer.geometry, candidate)) {
        pointer.geometry = candidate;
        pointer.revision +%= 1;
    }
}

/// Example: `queue.push(pointer.sample(event));`
pub fn sample(pointer: *const Routing, event: Event) Sample {
    var owned = event;
    owned.text = null;
    return .{ .event = owned, .geometry_revision = pointer.revision };
}

/// New gestures require current physical geometry; child drags keep their
/// original pane while copy-mode and chrome retain their own owners.
/// Example: `try pointer.apply(app, sample);`
pub fn apply(pointer: *Routing, app: *client.AttachedClient, value: Sample) !void {
    const event = value.event;
    const retained = event.code == 2 or event.code == 3;
    const button: usize = event.button;
    if (event.code == 1) {
        pointer.held[button] = null;
        pointer.owned[button] = true;
    }

    if (!retained and value.geometry_revision != pointer.revision) {
        return;
    }

    const mouse = pointer.geometry.resolve(event) orelse return;
    if (retained and pointer.owned[button]) {
        const capture = pointer.held[button];
        if (event.code == 2) {
            pointer.held[button] = null;
            pointer.owned[button] = false;
        }

        if (capture) |owner| {
            try owner.deliver(app, mouse);
        }
        return;
    }

    const outcome = try client.controllers.pointer_routing.apply(app, mouse);
    if (event.code == 1) {
        pointer.held[button] = null;
        pointer.owned[button] = outcome != .view and outcome != .copy_mode;
        if (outcome == .pane) {
            const selection = app.model.pointerSelection();
            if (selection != null and selection.?.dragging) {
                pointer.owned[button] = false;
            } else {
                pointer.held[button] = Capture.begin(app, mouse);
            }
        }
    }
}
