const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Canvas = @import("Canvas.zig");
const Rect = @import("../render/Rect.zig");
const HintPen = @import("HintPen.zig");
const Label = @import("Label.zig");
const ModeBar = @This();

mode: client.Mode,
area: Rect,

/// Presents the mode chip and the key hints already resolved by the shared
/// router, in the monospace face: keys are commands.
/// Example: `try mode_bar.draw(canvas);`
pub fn draw(bar: ModeBar, canvas: *Canvas) !void {
    const mode = bar.mode;
    if (mode == .normal or bar.area.width <= 0 or bar.area.height <= 0) {
        return;
    }

    const palette = canvas.theme.palette;
    const chrome = canvas.chrome;
    const title = if (mode == .copy) " COPY " else " PREFIX ";
    const chip_height = @min(bar.area.height, chrome.px(18));
    const chip: Rect = .{ .x = bar.area.x, .y = bar.area.y + @floor((bar.area.height - chip_height) / 2), .width = @min(try canvas.measure(.{ .text = title }), bar.area.width), .height = chip_height };
    try canvas.fillRoundedAt(chip, .{ .radius = chrome.px(4), .color = palette.accent });
    _ = try canvas.textAt(.{ .x = chip.x, .y = bar.area.y, .width = chip.width, .height = bar.area.height }, .{ .text = title, .color = palette.surface_dim, .bold = true });
    var pen: HintPen = .{ .x = chip.x + chip.width + chrome.px(8), .end = bar.area.x + bar.area.width, .y = bar.area.y, .height = bar.area.height };
    if (mode == .copy) {
        _ = try hint(canvas, &pen, plain(palette, " h/j/k/l move  v select  V lines  / search  y copy  o open  q exit "));
        return;
    }

    _ = try hint(canvas, &pen, plain(palette, "Esc cancel"));
    pen.x += chrome.px(12);
    for (mode.prefix.slice()) |item| {
        var key_storage: [48]u8 = undefined;
        const key = formatKey(&key_storage, item.key);
        if (!try hint(canvas, &pen, .{ .text = key, .color = palette.accent, .bold = true })) {
            break;
        }

        pen.x += chrome.px(4);
        if (!try hint(canvas, &pen, plain(palette, item.label))) {
            break;
        }

        pen.x += chrome.px(12);
    }
}

// Keys are commands in accent bold; labels are hints in `subtext0`. A hint
// that does not fit is skipped whole rather than clipped mid-word.
fn hint(canvas: *Canvas, pen: *HintPen, label: Label) !bool {
    const width = try canvas.measure(label);
    if (pen.x + width > pen.end) {
        return false;
    }

    _ = try canvas.textAt(.{ .x = pen.x, .y = pen.y, .width = width, .height = pen.height }, label);
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
