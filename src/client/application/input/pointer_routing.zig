//! Application policy for routing one normalized host pointer event.

const PointerCommand = @import("PointerCommand.zig");
const std = @import("std");

pub const Authority = union(enum) {
    unavailable,
    available: PointerCommand,
};

pub const Outcome = enum {
    unavailable,
    copy_mode,
    view,
    link,
    pane,
};

pub const Event = enum {
    copy_mode,
    view,
    link,
    pane,
};

pub const Failure = enum {
    none,
    copy_mode,
    view,
    link,
    pane,
};

fn testingCommand() PointerCommand {
    return .{
        .event = .{ .x = 4, .y = 7, .kind = .press },
        .exterior_pixels = false,
        .cell_width_px = 0,
        .cell_height_px = 0,
    };
}
