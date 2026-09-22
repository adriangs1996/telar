//! Shared pointer and focused-scroll policy after pane resolution.

const PointerCommand = @import("PointerCommand.zig");
const PaneMousePlanType = @import("../../workspace/PaneMousePlan.zig");
const Mouse = @import("../../input/Mouse.zig");
const Resolved = @import("Resolved.zig");

pub const Command = @import("../../types/PaneMouseCommand.zig").PaneMouseCommand;

pub const Effect = @import("../../types/PaneMouseEffect.zig").PaneMouseEffect;

pub const Outcome = @import("../../types/PaneMouseOutcome.zig").PaneMouseOutcome;

fn testingPlan() PaneMousePlanType {
    return .{
        .pane_id = @enumFromInt(3),
        .content = .{
            .x = 10,
            .y = 4,
            .w = 20,
            .h = 8,
        },
        .protocol = .{},
        .alternate_scroll = false,
        .at_bottom = true,
    };
}

fn testingPointer(kind: Mouse.Kind) PointerCommand {
    return .{
        .event = .{
            .x = 12,
            .y = 6,
            .kind = kind,
            .button = switch (kind) {
                .scroll_up => 64,
                .scroll_down => 65,
                else => 0,
            },
        },
        .exterior_pixels = false,
        .cell_width_px = 0,
        .cell_height_px = 0,
    };
}

fn testingCommand(kind: Mouse.Kind) Command {
    return .{
        .pointer = testingPointer(kind),
    };
}

fn testingResolved(kind: Mouse.Kind) Resolved {
    return .{
        .plan = testingPlan(),
        .pointer = testingPointer(kind),
    };
}
