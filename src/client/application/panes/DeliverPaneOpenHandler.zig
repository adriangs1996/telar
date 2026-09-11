const PaneOpenDeliveryEffects = @import("PaneOpenDeliveryEffects.zig");
const Command = @import("Command.zig");
const pane_open_delivery = @import("pane_open_delivery.zig");
const DeliverPaneOpenHandler = @This();

effects: PaneOpenDeliveryEffects,

/// Routes one already-correlated confirmation to its exact application
/// flow. Retired work has no effects.
///
/// ```zig
/// const outcome = try handler.execute(command);
/// ```
pub fn execute(handler: *DeliverPaneOpenHandler, command: Command) !pane_open_delivery.Outcome {
    return switch (command.continuation) {
        .initial_open => delivery: {
            try handler.effects.arrive_workspace(handler.effects.context, command.opened);
            break :delivery .workspace_arrived;
        },
        .create_workspace => |requested_size| delivery: {
            try handler.effects.create_workspace(handler.effects.context, .{
                .requested_size = requested_size,
                .opened = command.opened,
            });
            break :delivery .workspace_created;
        },
        .split => |requested| delivery: {
            try handler.effects.confirm_split(handler.effects.context, .{
                .requested = requested,
                .opened = command.opened,
            });
            break :delivery .pane_split;
        },
        .attach_pane => |requested| delivery: {
            try handler.effects.confirm_attachment(handler.effects.context, .{
                .requested = requested,
                .opened = command.opened,
            });
            break :delivery .pane_attached;
        },
        .ignored => .ignored,
    };
}
