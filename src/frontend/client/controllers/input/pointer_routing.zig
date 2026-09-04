//! Wires host pointer authority and normalization to client pointer owners.

const std = @import("std");
const core = @import("telar-core");
const presentation = @import("../../../presentation/root.zig");
const workspace_capability = @import("../../../workspace/root.zig");
const input_application = @import("../../application/input/root.zig");
const copy_mode_pointer = @import("copy_mode_pointer.zig");
const link_openings = @import("link_openings.zig");
const pane_mouse_inputs = @import("pane_mouse_inputs.zig");
const view_interactions = @import("view_interactions.zig");

const Client = @import("../../client.zig");
const diagnostics = core.diagnostics;
const multiplexer = workspace_capability.multiplexer;
const pointer_routing = input_application.pointer_routing;
const term = presentation.screen;

pub const Outcome = pointer_routing.Outcome;

const Context = struct {
    client: *Client,
    model: ?*multiplexer.Model = null,
};

/// Routes one host pointer event through the current exclusive owner.
///
/// ```zig
/// _ = try apply(client, event);
/// ```
pub fn apply(client: *Client, event: term.Event.Mouse) !Outcome {
    if (comptime diagnostics.enabled) {
        client.telemetry.metrics.mouse_events += 1;
    }

    var context: Context = .{ .client = client };

    var use_case: pointer_routing.PointerRoutingHandler = .{
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

fn link(raw_context: *anyopaque, command: pointer_routing.Command) !bool {
    const context: *Context = @ptrCast(@alignCast(raw_context));

    return link_openings.pointer(context.client, context.model.?, command.event);
}

fn resolve(context: *Context, event: term.Event.Mouse) pointer_routing.Authority {
    if (context.client.model.name_prompt.active()) {
        return .unavailable;
    }

    context.model = context.client.model.activeTabModel() orelse return .unavailable;

    const capabilities = context.client.model.hostCapabilities();
    const host_size = context.client.model.hostSize();
    const exterior_pixels = capabilities.mouse_pixels == .supported and
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

fn copyMode(raw_context: *anyopaque, command: pointer_routing.Command) !bool {
    const context: *Context = @ptrCast(@alignCast(raw_context));

    return copy_mode_pointer.apply(context.client, context.model.?, command.event);
}

fn view(raw_context: *anyopaque, command: pointer_routing.Command) !pointer_routing.ViewOutcome {
    const context: *Context = @ptrCast(@alignCast(raw_context));
    const interaction = context.client.view.handleMouse(command.event);
    const outcome = try view_interactions.apply(context.client, context.model.?, interaction);

    return .{
        .consume_pane_input = outcome.consume_pane_input,
        .pointer_inside = context.client.view.workbench().contains(command.event.x, command.event.y),
    };
}

fn pane(raw_context: *anyopaque, command: pointer_routing.Command) !void {
    const context: *Context = @ptrCast(@alignCast(raw_context));

    _ = try pane_mouse_inputs.apply(context.client, context.model.?, command);
}
