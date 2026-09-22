//! Wires host pointer authority and normalization to client pointer owners.

const data = @import("model");
const pointer_routing = @import("../../application/input/pointer_routing.zig");
const core = @import("telar-core");
const projection_support = @import("../../presentation/projection_support.zig");
const Client = @import("../../AttachedClient.zig");
const PointerRoutingContext = @import("PointerRoutingContext.zig");
const GeometryType = @import("../../presentation/Geometry.zig");
const std = @import("std");
const copy_mode_pointer = @import("copy_mode_pointer.zig");
const ViewOutcomeType = @import("../../application/input/ViewOutcome.zig");
const view_interactions = @import("view_interactions.zig");

/// Routes one host pointer event through the current exclusive owner.
///
/// ```zig
/// _ = try apply(client, event);
/// ```
pub fn apply(client: *Client, event: data.Mouse) !pointer_routing.Outcome {
    if (comptime core.enabled) {
        client.telemetry.metrics.mouse_events += 1;
    }

    var context: PointerRoutingContext = .{ .client = client };

    const command = switch (resolve(&context, event)) {
        .unavailable => return .unavailable,
        .available => |available| available,
    };

    if (try copyMode(&context, command)) {
        return .copy_mode;
    }

    const interaction = try view(&context, command);
    if (interaction.consume_pane_input or !interaction.pointer_inside) {
        return .view;
    }

    if (try link(&context, command)) {
        return .link;
    }

    try pane(&context, command);
    return .pane;
}

fn link(context: *PointerRoutingContext, command: data.PointerCommand) !bool {
    if (context.client.chrome.linkPointer(command.event)) |consumed| {
        return consumed;
    }

    return context.client.inputLinkPointer(context.model.?, command.event);
}

fn resolve(context: *PointerRoutingContext, event: data.Mouse) pointer_routing.Authority {
    const selection = context.client.model.pointerSelection();
    const captured = if (selection) |value| value.dragging else false;
    if (context.client.model.name_prompt.active() and !captured) {
        return .unavailable;
    }

    context.model = context.client.model.activeTabModel() orelse return .unavailable;
    const begins_gesture = event.kind == .press or event.kind == .scroll_up or event.kind == .scroll_down;
    if (begins_gesture and !captured and context.client.presentation.inFlight()) {
        const delivered = context.client.presentation.deliveredGeometry() orelse return .unavailable;
        const projection = projection_support.capture(&context.client.model, .{ .geometry = context.client.geometry() });
        const current = GeometryType.capture(projection);
        if (!delivered.matches(&current)) {
            return .unavailable;
        }
    }

    const capabilities = context.client.model.hostCapabilities();
    const host_size = context.client.model.hostSize();
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

fn copyMode(context: *PointerRoutingContext, command: data.PointerCommand) !bool {
    return copy_mode_pointer.apply(context.client, context.model.?, command.event);
}

fn view(context: *PointerRoutingContext, command: data.PointerCommand) !ViewOutcomeType {
    const interaction = context.client.chrome.pointer(command.event);
    const outcome = try view_interactions.apply(context.client, context.model.?, interaction);

    return .{
        .consume_pane_input = outcome.consume_pane_input,
        .pointer_inside = context.client.geometry().area.contains(command.event.x, command.event.y),
    };
}

fn pane(context: *PointerRoutingContext, command: data.PointerCommand) !void {
    _ = try context.client.inputPaneMouse(
        context.model.?,
        .{
            .pointer = command,
        },
    );
}
