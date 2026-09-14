const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Context = @import("Context.zig");
const Rect = @import("../render/Rect.zig");
const HintPen = @import("HintPen.zig");
const Label = @import("Label.zig");
const ModeBar = @This();

context: *Context,
area: Rect,

/// Presents the mode chip and the key hints already resolved by the shared
/// router, in the monospace face: keys are commands.
/// Example: `try mode_bar.paint();`
pub fn paint(bar: ModeBar) !void {
    const mode = bar.context.projection.status_mode;
    if (mode == .normal or bar.area.width <= 0 or bar.area.height <= 0) {
        return;
    }

    const canvas = bar.context.canvas;
    const palette = canvas.theme.palette;
    const chrome = canvas.chrome;
    const title = if (mode == .copy) " COPY " else " PREFIX ";
    const chip_height = @min(bar.area.height, chrome.px(18));
    const chip: Rect = .{ .x = bar.area.x, .y = bar.area.y + @floor((bar.area.height - chip_height) / 2), .width = @min(try canvas.measure(.{ .text = title }), bar.area.width), .height = chip_height };
    try canvas.fillRoundedPixels(chip, .{ .radius = chrome.px(4), .color = palette.accent });
    _ = try canvas.textPixels(.{ .x = chip.x, .y = bar.area.y, .width = chip.width, .height = bar.area.height }, .{ .text = title, .color = palette.surface_dim, .bold = true });
    var pen: HintPen = .{ .x = chip.x + chip.width + chrome.px(8), .end = bar.area.x + bar.area.width };
    if (mode == .copy) {
        _ = try bar.hint(&pen, plain(palette, " h/j/k/l move  v select  V lines  / search  y copy  o open  q exit "));
        return;
    }

    _ = try bar.hint(&pen, plain(palette, "Esc cancel"));
    pen.x += chrome.px(12);
    for (mode.prefix.slice()) |item| {
        var key_storage: [48]u8 = undefined;
        const key = formatKey(&key_storage, item.key);
        if (!try bar.hint(&pen, .{ .text = key, .color = palette.accent, .bold = true })) {
            break;
        }

        pen.x += chrome.px(4);
        if (!try bar.hint(&pen, plain(palette, item.label))) {
            break;
        }

        pen.x += chrome.px(12);
    }
}

// Keys are commands in accent bold; labels are hints in `subtext0`. A hint
// that does not fit is skipped whole rather than clipped mid-word.
fn hint(bar: ModeBar, pen: *HintPen, label: Label) !bool {
    const canvas = bar.context.canvas;
    const width = try canvas.measure(label);
    if (pen.x + width > pen.end) {
        return false;
    }

    _ = try canvas.textPixels(.{ .x = pen.x, .y = bar.area.y, .width = width, .height = bar.area.height }, label);
    pen.x += width;
    return true;
}

fn plain(palette: client.Palette, text: []const u8) Label {
    return .{ .text = text, .color = palette.subtext0 };
}

fn formatKey(buffer: []u8, key: client.Key) []const u8 {
    const code = switch (key.code) {
        .char => |character| character.slice(),
        .up => "Up",
        .down => "Down",
        .left => "Left",
        .right => "Right",
        .home => "Home",
        .end => "End",
        .delete => "Del",
        .page_up => "PgUp",
        .page_down => "PgDn",
        .enter => "Enter",
        .escape => "Esc",
        .backspace => "Backspace",
        .tab => "Tab",
        .back_tab => "BackTab",
    };
    return std.fmt.bufPrint(buffer, "{s}{s}{s}{s}", .{ if (key.mods.ctrl) "Ctrl+" else "", if (key.mods.alt) "Alt+" else "", if (key.mods.shift) "Shift+" else "", code }) catch "?";
}
