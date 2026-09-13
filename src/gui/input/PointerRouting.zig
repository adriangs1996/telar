//! Native geometry admission plus independent bounded gesture owners.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Geometry = @import("PointerGeometry.zig");
const Capture = @import("PointerCapture.zig");
const Sample = @import("PointerSample.zig");
const Event = @import("../native/InputEvent.zig").InputEvent;
const Routing = @This();
const GuiClient = @import("../GuiClient.zig");

geometry: Geometry = .{},
revision: u64 = 0,
gesture_revision: u64 = 0,
owners: [3]@import("pointer_owner.zig").Owner = @splat(.shared),
last: [3]client.Mouse = @splat(.{ .x = 0, .y = 0, .kind = .release }),
hover: @import("PointerHover.zig") = .{},
link_gesture: @import("LinkGesture.zig") = .{},

/// Example: `pointer.configure(origin, size);`
pub fn configure(pointer: *Routing, origin: [2]u32, size: core.TerminalSize) void {
    const candidate: Geometry = .{ .origin = origin, .size = size };
    if (!std.meta.eql(pointer.geometry, candidate)) {
        pointer.geometry = candidate;
        pointer.revision +%= 1;
        pointer.hover.dirty = true;
        pointer.link_gesture.cancel();
    }
}

/// Example: `queue.push(pointer.sample(event));`
pub fn sample(pointer: *const Routing, event: Event) Sample {
    var owned = event;
    owned.text = null;
    return .{ .event = owned, .geometry_revision = pointer.revision, .gesture_revision = pointer.gesture_revision };
}

/// Invalidates queued gesture starts while an ordered cancellation waits for
/// transport capacity. Example: `pointer.invalidateGestures();`
pub fn invalidateGestures(pointer: *Routing) void {
    pointer.gesture_revision +%= 1;
}

/// New gestures require current physical geometry; child drags keep their
/// original pane while copy-mode and chrome retain their own owners.
/// Example: `try pointer.apply(app, sample);`
pub fn apply(pointer: *Routing, app: *client.AttachedClient, value: Sample) !void {
    const event = value.event;
    if (event.code == 7) {
        pointer.hover.clear();
        pointer.link_gesture.cancel();
        GuiClient.of(app).chrome.leavePointer();
        return;
    }

    const retained = event.code == 2 or event.code == 3;
    const button: usize = event.button;
    if (event.code == 1 and pointer.owners[button] == .shared) {
        pointer.owners[button] = .discarded;
    }

    if (!retained and value.geometry_revision != pointer.revision) {
        return;
    }

    pointer.hover.observe(event);
    if (event.code != 6) {
        pointer.hover.dirty = true;
    }

    pointer.hover.refresh(GuiClient.of(app));

    if (event.code == 6 and pointer.owners[0] == .link) {
        pointer.link_gesture.validate(pointer.hover.link, app.model.version());
        return;
    }

    const begins = event.code == 1 or event.code == 4 or event.code == 5;
    if (begins and (value.gesture_revision != pointer.gesture_revision or !geometryMatches(app))) {
        return;
    }

    const mouse = pointer.geometry.resolve(event) orelse return;
    if (event.code <= 3) {
        pointer.last[button] = mouse;
    }

    if (retained) {
        switch (pointer.owners[button]) {
            .child => |*capture| {
                try capture.deliver(app, mouse);
                if (event.code == 2) {
                    pointer.owners[button] = .shared;
                }

                return;
            },
            .link => {
                if (event.code == 3) {
                    pointer.link_gesture.cancel();
                }

                if (event.code == 2) {
                    pointer.owners[button] = .shared;
                    pointer.hover.dirty = true;
                    pointer.hover.refresh(GuiClient.of(app));
                    const target = if (geometryMatches(app) and pointer.hover.openable()) pointer.link_gesture.finish(pointer.hover.link, app.model.version()) else null;
                    pointer.link_gesture.cancel();
                    if (target) |selected| {
                        _ = try client.controllers.link_openings.apply(app, selected);
                    }
                }

                return;
            },
            .discarded => {
                if (event.code == 2) {
                    pointer.owners[button] = .shared;
                }

                return;
            },
            .shared => {},
        }
    }

    const outcome = try client.controllers.pointer_routing.apply(app, mouse);
    if (event.code <= 5) {
        pointer.hover.dirty = true;
    }
    if (event.code == 1) {
        pointer.owners[button] = switch (outcome) {
            .view, .copy_mode => .shared,
            .link => .link,
            .unavailable => .discarded,
            .pane => pane: {
                if (app.model.pointerSelection()) |selection| {
                    if (selection.dragging) {
                        break :pane .shared;
                    }
                }

                const capture = Capture.begin(app, mouse) orelse break :pane .discarded;
                break :pane .{ .child = capture };
            },
        };
    }
}

/// Closes existing gestures on focus loss, without assigning their releases
/// to chrome or to a pane that happens to be focused. Example: `try pointer.cancel(app);`
pub fn cancel(pointer: *Routing, app: *client.AttachedClient) !void {
    pointer.hover.clear();
    pointer.link_gesture.cancel();
    defer pointer.owners = @splat(.shared);
    for (&pointer.owners, pointer.last) |*owner, last| {
        switch (owner.*) {
            .child => |*capture| {
                var released = last;
                released.kind = .release;
                released.button &= 31;
                try capture.deliver(app, released);
            },
            .link => {},
            .shared, .discarded => {},
        }
    }

    if (app.model.pointerSelection()) |selection| {
        if (selection.dragging) {
            if (app.model.activeTabModel()) |model| {
                var released = pointer.last[0];
                released.kind = .release;
                released.button = 0;
                _ = try client.controllers.copy_mode_pointer.apply(app, model, released);
            }
        }
    }
}

fn geometryMatches(app: *client.AttachedClient) bool {
    const delivered = app.presentation.deliveredGeometry() orelse return false;
    const projection = client.capture(&app.model, .{ .geometry = app.geometry() });
    const current = client.Geometry.capture(projection);
    return delivered.matches(&current);
}
