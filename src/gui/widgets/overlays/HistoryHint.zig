//! A key and the word for what it does, in the history footer or on the
//! selected card. A hint with an action is also the control its key
//! triggers, so the pointer reaches everything the keys do without buttons.
const Canvas = @import("../Canvas.zig");
const Label = @import("../Label.zig");
const Target = @import("../interaction/Target.zig");
const PaletteRow = @import("PaletteRow.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const HistoryHint = @This();

/// Controls of one prompt share an action only across namespaces.
pub const Namespace = enum(u64) {
    footer = 5,
    card = 6,
};

/// Logical padding on each side of the text inside the control.
const padding: f32 = 6;

/// The control's rectangle; the text starts `padding` inside it.
bounds: Rect,
key: []const u8,
word: []const u8,
action: ?Target.Action = null,
enabled: bool = true,
generation: u64,
namespace: Namespace,

/// The width the control needs for its keycap and its word.
/// Example: `hint.bounds.width = try hint.width(canvas);`
pub fn width(self: HistoryHint, canvas: *Canvas) !f32 {
    const px = canvas.chrome;
    return try self.keyWidth(canvas) + px.px(6) + try canvas.measure(self.wordLabel(canvas)) + px.px(padding * 2);
}

/// Registers the control with the rectangle it paints and lights it under
/// the pointer. The key is the keycap the command palette draws.
/// Example: `try hint.draw(canvas);`
pub fn draw(self: HistoryHint, canvas: *Canvas) !void {
    if (self.bounds.width <= 0 or self.bounds.height <= 0) {
        return;
    }

    const px = canvas.chrome;
    var hovered = false;
    if (self.action) |action| {
        if (canvas.widgets) |state| {
            const target = (Target{
                .id = .{ .generation = self.generation },
                .namespace = @intFromEnum(self.namespace),
                .bounds = self.bounds,
                .action = action,
                .layer = 1,
                .focusable = false,
                .enabled = self.enabled,
            }).labelled(self.word);
            const id = try state.dispatcher.add(target);
            hovered = if (state.dispatcher.hovered) |hover| hover.eql(id) else false;
        }
    }

    if (hovered and self.enabled) {
        try canvas.fillRoundedAt(self.bounds, .{ .color = canvas.theme.palette.surface1, .radius = px.px(4) });
    }

    const first = canvas.quads.items().len;
    const x = self.bounds.x + px.px(padding);
    const limit = self.bounds.x + self.bounds.width;
    const key_width = @min(try self.keyWidth(canvas), @max(0, limit - x));
    try PaletteRow.keycap(canvas, .{ .x = x, .y = self.bounds.y, .width = key_width, .height = self.bounds.height }, self.key);
    const word_x = x + key_width + px.px(6);
    _ = try canvas.textAt(.{ .x = word_x, .y = self.bounds.y, .width = @max(0, limit - word_x), .height = self.bounds.height }, self.wordLabel(canvas));
    canvas.quads.clipFrom(first, self.bounds);
}

fn keyWidth(self: HistoryHint, canvas: *Canvas) !f32 {
    const px = canvas.chrome;
    return @max(px.px(22), try canvas.measure(.{ .text = self.key, .face = .sans, .size = .small }) + px.px(10));
}

fn wordLabel(self: HistoryHint, canvas: *const Canvas) Label {
    return .{ .text = self.word, .face = .sans, .size = .small, .color = canvas.theme.palette.subtext0 };
}
