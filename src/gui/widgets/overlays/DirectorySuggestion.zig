//! A folder completion carrying the listing revision that produced its label.
const Canvas = @import("../Canvas.zig");
const Target = @import("../interaction/Target.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const TextFit = @import("../TextFit.zig");
const PathCompletionChoice = @import("../interaction/PathCompletionChoice.zig");
const Label = @import("../Label.zig");
const Suggestion = @This();

bounds: Rect,
name: []const u8,
choice: PathCompletionChoice,
generation: u64,
selected: bool,
enabled: bool,

/// Example: `try suggestion.draw(canvas);`
pub fn draw(self: Suggestion, canvas: *Canvas) !void {
    const target = (Target{ .id = .{ .generation = self.generation }, .bounds = self.bounds, .action = .{ .complete_path = self.choice }, .layer = 1, .focusable = false, .enabled = self.enabled }).labelled(self.name);
    var hovered = false;
    if (canvas.widgets) |state| {
        const id = try state.dispatcher.add(target);
        hovered = if (state.dispatcher.hovered) |hover| hover.eql(id) else false;
    }

    const palette = canvas.theme.palette;
    if (self.selected or hovered) {
        try canvas.fillRoundedAt(self.bounds, .{ .color = if (self.selected) palette.surface1 else palette.surface0, .radius = canvas.chrome.px(5) });
    }

    const inset = canvas.chrome.px(10);
    const icon_width = canvas.chrome.px(18);
    try canvas.iconAt(.{ .x = self.bounds.x + inset, .y = self.bounds.y, .width = icon_width, .height = self.bounds.height }, .{ .text = "\u{f07b}", .color = palette.subtext0, .size = .body });
    const text: Rect = .{ .x = self.bounds.x + inset * 2 + icon_width, .y = self.bounds.y, .width = @max(0, self.bounds.width - inset * 3 - icon_width * 2), .height = self.bounds.height };
    var label: Label = .{ .text = self.name, .face = .sans, .size = .body, .color = palette.text, .alpha = if (self.enabled) 1 else 0.5 };
    var buffer: [TextFit.max_bytes]u8 = undefined;
    label.text = try (TextFit{ .canvas = canvas, .width = text.width }).fit(label, &buffer);
    _ = try canvas.textAt(text, label);
    _ = try canvas.textAt(.{ .x = self.bounds.x + self.bounds.width - inset - icon_width, .y = self.bounds.y, .width = icon_width, .height = self.bounds.height }, .{ .text = "›", .face = .sans, .size = .body, .color = palette.subtext0 });
}
