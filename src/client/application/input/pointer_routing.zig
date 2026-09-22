//! Application policy for routing one normalized host pointer event.

const data = @import("model");

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

fn testingCommand() data.PointerCommand {
    return .{
        .event = .{ .x = 4, .y = 7, .kind = .press },
        .exterior_pixels = false,
        .cell_width_px = 0,
        .cell_height_px = 0,
    };
}
