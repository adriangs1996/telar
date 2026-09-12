//! Wires host pointer authority and normalization to client pointer owners.

const Client = @import("../../AttachedClient.zig");
const MouseType = @import("../../input/Mouse.zig");
const ApplicationInputPointerRoutingOutcome = @import("../../application/input/pointer_routing.zig").Outcome;
const enabled_module = @import("telar-core").enabled;
const PointerRoutingContext = @import("PointerRoutingContext.zig");
const PointerRoutingHandlerType = @import("../../application/input/PointerRoutingHandler.zig");
const PointerCommandType = @import("../../application/input/PointerCommand.zig");
const link_openings = @import("link_openings.zig");
const AuthorityType = @import("../../application/input/pointer_routing.zig").Authority;
const capture_module = @import("../../presentation/projection_support.zig").capture;
const GeometryType = @import("../../presentation/Geometry.zig");
const std = @import("std");
const copy_mode_pointer = @import("copy_mode_pointer.zig");
const ViewOutcomeType = @import("../../application/input/ViewOutcome.zig");
const view_interactions = @import("view_interactions.zig");
const pane_mouse_inputs = @import("pane_mouse_inputs.zig");

/// Routes one host pointer event through the current exclusive owner.
///
/// ```zig
/// _ = try apply(client, event);
/// ```
pub fn apply(client: *Client, event: MouseType) !ApplicationInputPointerRoutingOutcome {
    if (comptime enabled_module) {
        client.telemetry.metrics.mouse_events += 1;
    }

    var context: PointerRoutingContext = .{ .client = client };

    var use_case: PointerRoutingHandlerType = .{
        .effects = .{
            .context = &context,
            .copy_mode = copyMode,
            .view = view,
            .link = link,
            .pane = pane,
        },
    };

    return use_case.execute(resolve(&context, event));
}

fn link(raw_context: *anyopaque, command: PointerCommandType) !bool {
    const context: *PointerRoutingContext = @ptrCast(@alignCast(raw_context));

    return link_openings.pointer(context.client, context.model.?, command.event);
}

fn resolve(context: *PointerRoutingContext, event: MouseType) AuthorityType {
    const selection = context.client.model.pointerSelection();
    const captured = if (selection) |value| value.dragging else false;
    if (context.client.model.name_prompt.active() and !captured) {
        return .unavailable;
    }

    context.model = context.client.model.activeTabModel() orelse return .unavailable;
    const begins_gesture = event.kind == .press or event.kind == .scroll_up or event.kind == .scroll_down;
    if (begins_gesture and !captured and context.client.presentation.inFlight()) {
        const delivered = context.client.presentation.deliveredGeometry() orelse return .unavailable;
        const projection = capture_module(&context.client.model, .{ .geometry = context.client.geometry() });
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

fn copyMode(raw_context: *anyopaque, command: PointerCommandType) !bool {
    const context: *PointerRoutingContext = @ptrCast(@alignCast(raw_context));

    return copy_mode_pointer.apply(context.client, context.model.?, command.event);
}

fn view(raw_context: *anyopaque, command: PointerCommandType) !ViewOutcomeType {
    const context: *PointerRoutingContext = @ptrCast(@alignCast(raw_context));
    const interaction = context.client.chrome.pointer(command.event);
    const outcome = try view_interactions.apply(context.client, context.model.?, interaction);

    return .{
        .consume_pane_input = outcome.consume_pane_input,
        .pointer_inside = context.client.geometry().area.contains(command.event.x, command.event.y),
    };
}

fn pane(raw_context: *anyopaque, command: PointerCommandType) !void {
    const context: *PointerRoutingContext = @ptrCast(@alignCast(raw_context));

    _ = try pane_mouse_inputs.apply(
        context.client,
        context.model.?,
        .{ .pointer = command },
    );
}
