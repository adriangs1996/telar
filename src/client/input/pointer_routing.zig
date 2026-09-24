//! Wires host pointer authority and normalization to client pointer owners.
const keyinput = @import("keyinput");

const data = @import("model");
const core = @import("telar-core");
const projection_support = @import("../presentation/projection_support.zig");
const Client = @import("../execution/Client.zig");
const Geometry = @import("../presentation/Geometry.zig");
const std = @import("std");
const copy_mode_pointer = @import("copy_mode_pointer.zig");
const view_interactions = @import("view_interactions.zig");
const link_opening = @import("../links/link_opening.zig");
const pane_mouse_input = @import("pane_mouse_inputs.zig");

/// Routes one host pointer event through the current exclusive owner.
///
/// ```zig
/// _ = try apply(client, event);
/// ```
pub fn apply(client: *Client, event: keyinput.Mouse) !Outcome {
    if (comptime core.enabled) {
        client.telemetry.metrics.mouse_events += 1;
    }

    const tab = client.model.tabs.activeSlot() orelse return .unavailable;
    const command = switch (resolve(client, event)) {
        .unavailable => return .unavailable,
        .available => |available| available,
    };

    if (try copy_mode_pointer.apply(client, tab, command.event)) {
        return .copy_mode;
    }

    const interaction = client.chrome.pointer(command.event);
    const outcome = try view_interactions.apply(client, tab, interaction);
    const pointer_inside = client.geometry().area.contains(command.event.x, command.event.y);
    if (outcome.consume_pane_input or !pointer_inside) {
        return .view;
    }

    const link_consumed = client.chrome.linkPointer(command.event) orelse try link_opening.inputLinkPointer(client, tab, command.event);
    if (link_consumed) {
        return .link;
    }

    _ = try pane_mouse_input.inputPaneMouse(client, tab, .{
        .pointer = command,
    });
    return .pane;
}

fn resolve(client: *Client, event: keyinput.Mouse) Authority {
    const selection = client.model.pointerSelection();
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

pub const Outcome = enum {
    unavailable,
    copy_mode,
    view,
    link,
    pane,
};
