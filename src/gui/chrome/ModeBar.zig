const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Context = @import("Context.zig");
const Strip = @import("Strip.zig");
const ModeBar = @This();

context: *Context,
area: core.Rect,

/// Presents the configured key hints already resolved by the shared router.
/// Example: `try mode_bar.paint();`
pub fn paint(bar: ModeBar) !void {
    const mode = bar.context.projection.status_mode;
    if (mode == .normal or bar.area.isEmpty()) {
        return;
    }

    const palette = bar.context.canvas.theme.palette;
    var strip: Strip = .{ .area = bar.area };
    const title = if (mode == .copy) " COPY " else " PREFIX ";
    const title_area = strip.take(core.measure(title));
    try bar.context.canvas.fill(title_area, palette.accent);
    try bar.context.canvas.text(title_area, .{ .text = title, .color = palette.surface_dim, .bold = true });
    if (mode == .copy) {
        try bar.context.label(strip.take(strip.remaining()), " h/j/k/l move  v select  V lines  / search  y copy  o open  q exit ");
        return;
    }

    try bar.context.label(strip.take(12), " Esc cancel ");
    for (mode.prefix.slice()) |hint| {
        var key_storage: [48]u8 = undefined;
        const key = formatKey(&key_storage, hint.key);
        try bar.context.canvas.text(strip.take(core.measure(key)), .{ .text = key, .color = palette.accent, .bold = true });
        _ = strip.take(1);
        try bar.context.label(strip.take(core.measure(hint.label)), hint.label);
        _ = strip.take(2);
    }
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
