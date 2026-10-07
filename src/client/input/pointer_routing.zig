//! Wires host pointer authority and normalization to client pointer owners.
const keyinput = @import("keyinput");

const data = @import("model");
const core = @import("telar-core");
const projection_support = @import("../presentation/projection_support.zig");
const Client = @import("../execution/Client.zig");
const ViewInteractionCommand = @import("ViewInteractionCommand.zig");
const Route = @import("PointerRoute.zig");
const Geometry = @import("../presentation/Geometry.zig");
const std = @import("std");
const copy_mode_pointer = @import("copy_mode_pointer.zig");
const view_interactions = @import("view_interactions.zig");
const link_opening = @import("../links/link_opening.zig");
const pane_mouse_input = @import("pane_mouse_inputs.zig");

/// Routes one pointer event of a host without chrome of its own through the
/// current exclusive owner. A host that draws chrome runs the steps itself
/// and answers its own hit testing between them.
///
/// ```zig
/// _ = try apply(client, event);
/// ```
pub fn apply(client: *Client, event: keyinput.Mouse) !Outcome {
    const route = switch (try admit(client, event)) {
        .settled => |outcome| return outcome,
        .routed => |value| value,
    };

    if (try interact(client, route, .{})) {
        return .view;
    }

    return deliver(client, route, null);
}

/// Resolves the pointer's authority and lets copy mode take it first. What
/// copy mode leaves is routed to the host's chrome, then `interact`.
///
/// ```zig
/// const admission = try admit(client, event);
/// ```
pub fn admit(client: *Client, event: keyinput.Mouse) !Admission {
    if (comptime core.enabled) {
        client.telemetry.metrics.mouse_events += 1;
    }

    const tab = client.model.tabs.activeSlot() orelse return .{ .settled = .unavailable };
    const command = switch (resolve(client, event)) {
        .unavailable => return .{ .settled = .unavailable },
        .available => |available| available,
    };

    if (try copy_mode_pointer.apply(client, tab, command.event)) {
        return .{ .settled = .copy_mode };
    }

    return .{ .routed = .{
        .tab = tab,
        .command = command,
    } };
}

/// Applies what the host's chrome answered for the routed event. Returns
/// true when the view keeps the event: it consumed it or it fell outside
/// the grid.
///
/// ```zig
/// if (try interact(client, route, interaction)) return .view;
/// ```
pub fn interact(client: *Client, route: Route, interaction: ViewInteractionCommand) !bool {
    const outcome = try view_interactions.apply(client, route.tab, interaction);
    const pointer_inside = client.geometry().area.contains(route.command.event.x, route.command.event.y);
    return outcome.consume_pane_input or !pointer_inside;
}

/// Gives the event to a link or to the pane. `link` is the host's own link
/// gesture answer; null leaves links to the shared routing.
///
/// ```zig
/// const outcome = try deliver(client, route, null);
/// ```
pub fn deliver(client: *Client, route: Route, link: ?bool) !Outcome {
    const link_consumed = link orelse try link_opening.inputLinkPointer(client, route.tab, route.command.event);
    if (link_consumed) {
        return .link;
    }

    _ = try pane_mouse_input.inputPaneMouse(client, route.tab, .{
        .pointer = route.command,
    });
    return .pane;
}

fn resolve(client: *Client, event: keyinput.Mouse) Authority {
    const selection = data.copy_mode.pointerSelection(&client.model);
    const captured = if (selection) |value| value.dragging else false;
    if (client.model.name_prompt.active() and !captured) {
        return .unavailable;
    }

    const begins_gesture = event.kind == .press or event.kind == .scroll_up or event.kind == .scroll_down;
    if (begins_gesture and !captured and client.presentation.active != null) {
        const delivered = client.presentation.delivered_geometry orelse return .unavailable;
        const projection = projection_support.capture(&client.model, .{ .geometry = client.geometry() });
        const current = Geometry.capture(projection);
        if (!delivered.matches(&current)) {
            return .unavailable;
        }
    }

    const capabilities = client.model.host.host_capabilities;
    const host_size = client.model.host.host_size;
    const exterior_pixels = capabilities.pointer_pixels == .supported and
        host_size.cell_width_px != 0 and host_size.cell_height_px != 0;
    var cell_event = event;
    if (exterior_pixels) {
        cell_event.x = std.math.cast(u16, event.raw_x / host_size.cell_width_px) orelse
            std.math.maxInt(u16);
        cell_event.y = std.math.cast(u16, event.raw_y / host_size.cell_height_px) orelse
            std.math.maxInt(u16);
    }

    return .{ .available = .{
        .event = cell_event,
        .exterior_pixels = exterior_pixels,
        .cell_width_px = host_size.cell_width_px,
        .cell_height_px = host_size.cell_height_px,
    } };
}

pub const Authority = union(enum) {
    unavailable,
    available: data.PointerCommand,
};

pub const Admission = union(enum) {
    settled: Outcome,
    routed: Route,
};

pub const Outcome = enum {
    unavailable,
    copy_mode,
    view,
    link,
    pane,
};
