//! Projection from host mouse events to a focused pane's SGR protocol.

const std = @import("std");
const core = @import("telar-core");
const Mouse = @import("key_support.zig").Mouse;

const schema = core.schema;
pub const ui = core.ui;

pub const PixelPoint = @import("PixelPoint.zig");

pub const CellSize = @import("CellSize.zig");

pub const PixelProjection = @import("PixelProjection.zig");

pub const SgrInput = @import("SgrInput.zig");

pub fn tracked(tracking: schema.frame.MouseTracking, kind: Mouse.Kind) bool {
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
