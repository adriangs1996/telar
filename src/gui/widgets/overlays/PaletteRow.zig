//! A palette result: icon, label, optional detail and trailing shortcut.
const cellgrid = @import("cellgrid");
const Canvas = @import("../Canvas.zig");
const Label = @import("../Label.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const PaletteRow = @This();

area: cellgrid.Rect = .{},
icon: []const u8,
primary: []const u8,
secondary: []const u8 = "",
hint: []const u8 = "",
mono: bool = false,
color: ?cellgrid.Color = null,
selected: bool = false,
detail_below: bool = false,
shortcut: bool = false,
checked: bool = false,
swatch: ?[3]cellgrid.Color = null,

/// Legacy cell consumers can still supply a cell rectangle.
/// Example: `try row.draw(canvas);`
pub fn draw(self: PaletteRow, canvas: *Canvas) !void {
    try self.drawAt(canvas, canvas.rect(self.area));
}

/// Shares exact device-pixel geometry with the delivered result target.
/// Example: `try row.drawAt(canvas, bounds);`
pub fn drawAt(self: PaletteRow, canvas: *Canvas, bounds: Rect) !void {
    if (bounds.width <= 0 or bounds.height <= 0) {
        return;
    }

    const first = canvas.quads.items().len;
    defer canvas.quads.clipFrom(first, bounds);
    const px = canvas.chrome;
    const colors = canvas.theme.palette;
    if (self.selected) {
        try canvas.fillRoundedAt(bounds, .{ .color = colors.surface0, .radius = px.px(6) });
        try canvas.fillRoundedAt(bounds, .{ .color = colors.accent, .alpha = 0.08, .radius = px.px(6) });
        try canvas.ringAt(bounds, .{ .color = colors.accent, .alpha = 0.2, .width = px.px(1), .radius = px.px(6) });
    }

    const inset = @min(px.px(10), bounds.width / 8);
    var body: Rect = .{ .x = bounds.x + inset, .y = bounds.y, .width = @max(0, bounds.width - inset * 2), .height = bounds.height };
    if (self.icon.len > 0 or self.swatch != null) {
        const side = @min(px.px(20), body.width);
        const icon_box: Rect = .{ .x = body.x, .y = body.y + (body.height - @min(side, body.height)) / 2, .width = side, .height = @min(side, body.height) };
        if (self.swatch) |swatch| {
            try canvas.fillRoundedAt(icon_box, .{ .color = swatch[0], .radius = px.px(4) });
            try canvas.fillAt(.{ .x = icon_box.x + side / 5, .y = icon_box.y + icon_box.height / 2, .width = side / 3, .height = icon_box.height / 3 }, swatch[1]);
            try canvas.fillAt(.{ .x = icon_box.x + side / 2, .y = icon_box.y + icon_box.height / 2, .width = side / 3, .height = icon_box.height / 3 }, swatch[2]);
            try canvas.ringAt(icon_box, .{ .color = colors.text, .alpha = 0.18, .width = px.px(1), .radius = px.px(4) });
        } else {
            try canvas.iconAt(icon_box, .{ .text = self.icon, .color = colors.text, .alpha = 0.65, .size = .body });
        }

        const used = @min(body.width, side + px.px(10));
        body.x += used;
        body.width -= used;
    }

    if (self.checked) {
        const check_width = @min(body.width, px.px(24));
        _ = try canvas.textAt(.{ .x = body.x + body.width - check_width, .y = body.y, .width = check_width, .height = body.height }, .{ .text = "✓", .color = colors.accent, .size = .small, .face = .sans });
        body.width = @max(0, body.width - check_width - px.px(8));
    }

    const hint: Label = .{ .text = if (self.hint.len != 0) self.hint else if (!self.detail_below) self.secondary else "", .color = colors.text, .alpha = 0.65, .size = .small, .face = .sans };
    const hint_width = @min(try canvas.measure(hint) + if (self.shortcut) px.px(10) else @as(f32, 0), body.width * 0.45);
    if (hint.text.len != 0) {
        const right: Rect = .{ .x = body.x + body.width - hint_width, .y = body.y, .width = hint_width, .height = body.height };
        if (self.shortcut) {
            try keycap(canvas, right, hint.text);
        } else {
            _ = try canvas.textAt(right, hint);
        }

        body.width = @max(0, body.width - hint_width - px.px(12));
    }

    const primary: Label = .{ .text = self.primary, .color = self.color orelse colors.text, .face = if (self.mono) .mono else .sans, .size = .body };
    if (self.detail_below and self.secondary.len > 0) {
        const text_height = px.rowHeight(.body) + px.rowHeight(.small);
        var upper = body;
        upper.y += @max(0, (body.height - text_height) / 2);
        upper.height = @min(body.height, px.rowHeight(.body));
        _ = try canvas.textAt(upper, primary);
        var lower = upper;
        lower.y += upper.height;
        lower.height = @min(px.rowHeight(.small), @max(0, body.y + body.height - lower.y));
        _ = try canvas.textAt(lower, .{ .text = self.secondary, .color = colors.text, .alpha = 0.65, .face = .sans, .size = .small });
    } else {
        _ = try canvas.textAt(body, primary);
    }
}

/// A compact keyboard hint, vertically centered in its reserved slot.
/// Example: `try PaletteRow.keycap(canvas, bounds, "esc");`
pub fn keycap(canvas: *Canvas, bounds: Rect, text: []const u8) !void {
    const height = @min(bounds.height, @max(canvas.chrome.px(20), canvas.chrome.rowHeight(.small) + canvas.chrome.px(4)));
    const box: Rect = .{ .x = bounds.x, .y = bounds.y + (bounds.height - height) / 2, .width = bounds.width, .height = height };
    try canvas.ringAt(box, .{ .color = canvas.theme.palette.text, .alpha = 0.2, .width = canvas.chrome.px(1), .radius = canvas.chrome.px(4) });
    const label: Label = .{ .text = text, .face = .sans, .size = .small, .color = canvas.theme.palette.text, .alpha = 0.7 };
    const width = @min(try canvas.measure(label), box.width);
    _ = try canvas.textAt(.{ .x = box.x + (box.width - width) / 2, .y = box.y, .width = width, .height = box.height }, label);
}
