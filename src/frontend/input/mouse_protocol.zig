//! Projection from host mouse events to a focused pane's SGR protocol.

const std = @import("std");
const core = @import("telar-core");
const term = @import("../presentation/root.zig").screen;

const schema = core.schema;

pub fn tracked(tracking: schema.frame.MouseTracking, kind: term.Event.Mouse.Kind) bool {
    return switch (tracking) {
        .none => false,
        .x10 => kind == .press,
        .normal => kind == .press or kind == .release or
            kind == .scroll_up or kind == .scroll_down,
        .button => kind != .move,
        .any => true,
    };
}

pub fn encodeSgr(
    buffer: []u8,
    event: term.Event.Mouse,
    pane_x: u16,
    pane_y: u16,
    pixels: bool,
    cell_width: u16,
    cell_height: u16,
    exact_pixel_x: ?u32,
    exact_pixel_y: ?u32,
) ![]const u8 {
    const final: u8 = if (event.kind == .release) 'm' else 'M';
    const x: u32 = exact_pixel_x orelse if (pixels and cell_width != 0)
        @as(u32, pane_x) * cell_width + cell_width / 2
    else
        pane_x;
    const y: u32 = exact_pixel_y orelse if (pixels and cell_height != 0)
        @as(u32, pane_y) * cell_height + cell_height / 2
    else
        pane_y;
    return std.fmt.bufPrint(buffer, "\x1b[<{d};{d};{d}{c}", .{
        event.button,
        x + 1,
        y + 1,
        final,
    });
}
