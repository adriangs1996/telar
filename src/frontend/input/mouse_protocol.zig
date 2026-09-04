//! Projection from host mouse events to a focused pane's SGR protocol.

const std = @import("std");
const core = @import("telar-core");
const term = @import("../presentation/root.zig").screen;

const schema = core.schema;
const ui = core.ui;

pub const PixelPoint = struct {
    x: u32,
    y: u32,
};

pub const CellSize = struct {
    width: u16,
    height: u16,
};

pub const PixelProjection = struct {
    cell: CellSize,
    exact: ?PixelPoint = null,
};

pub const SgrInput = struct {
    event: term.Event.Mouse,
    pane_position: ui.Point,
    pixels: ?PixelProjection = null,
};

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

/// Encodes one pane-relative mouse event using the SGR protocol.
/// For example: `const bytes = try encodeSgr(&buffer, .{ .event = event, .pane_position = .{ .x = 2, .y = 4 } });`.
pub fn encodeSgr(buffer: []u8, input: SgrInput) ![]const u8 {
    const final: u8 = if (input.event.kind == .release) 'm' else 'M';
    const x: u32 = if (input.pixels) |pixels|
        if (pixels.exact) |exact| exact.x else if (pixels.cell.width != 0)
            @as(u32, input.pane_position.x) * pixels.cell.width + pixels.cell.width / 2
        else
            input.pane_position.x
    else
        input.pane_position.x;
    const y: u32 = if (input.pixels) |pixels|
        if (pixels.exact) |exact| exact.y else if (pixels.cell.height != 0)
            @as(u32, input.pane_position.y) * pixels.cell.height + pixels.cell.height / 2
        else
            input.pane_position.y
    else
        input.pane_position.y;
    return std.fmt.bufPrint(buffer, "\x1b[<{d};{d};{d}{c}", .{
        input.event.button,
        x + 1,
        y + 1,
        final,
    });
}
