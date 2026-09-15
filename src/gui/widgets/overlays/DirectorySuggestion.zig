//! A folder completion carrying the listing revision that produced its label.
const Canvas = @import("../Canvas.zig");
const Target = @import("../interaction/Target.zig");
const Rect = @import("../../render/Rect.zig");
const TextFit = @import("../TextFit.zig");
const Suggestion = @This();

bounds: Rect,
name: []const u8,
choice: @import("../interaction/PathCompletionChoice.zig"),
generation: u64,
selected: bool,
enabled: bool,

/// Example: `try suggestion.draw(canvas);`
pub fn draw(row: Suggestion, canvas: *Canvas) !void {
    const target = (Target{ .id = .{ .generation = row.generation }, .bounds = row.bounds, .action = .{ .complete_path = row.choice }, .layer = 1, .focusable = false, .enabled = row.enabled }).labelled(row.name);
    var hovered = false;
    if (canvas.widgets) |state| {
        const id = try state.dispatcher.add(target);
        hovered = if (state.dispatcher.hovered) |hover| hover.eql(id) else false;
    }

    const palette = canvas.theme.palette;
    if (row.selected or hovered) {
        try canvas.fillRoundedAt(row.bounds, .{ .color = if (row.selected) palette.surface1 else palette.surface0, .radius = canvas.chrome.px(5) });
    }

    const inset = canvas.chrome.px(10);
    const icon_width = canvas.chrome.px(18);
    try canvas.iconAt(.{ .x = row.bounds.x + inset, .y = row.bounds.y, .width = icon_width, .height = row.bounds.height }, .{ .text = "\u{f07b}", .color = palette.subtext0, .size = .body });
    const text: Rect = .{ .x = row.bounds.x + inset * 2 + icon_width, .y = row.bounds.y, .width = @max(0, row.bounds.width - inset * 3 - icon_width * 2), .height = row.bounds.height };
    var label: @import("../Label.zig") = .{ .text = row.name, .face = .sans, .size = .body, .color = palette.text, .alpha = if (row.enabled) 1 else 0.5 };
    var buffer: [TextFit.max_bytes]u8 = undefined;
    label.text = try (TextFit{ .canvas = canvas, .width = text.width }).fit(label, &buffer);
    _ = try canvas.textAt(text, label);
    _ = try canvas.textAt(.{ .x = row.bounds.x + row.bounds.width - inset - icon_width, .y = row.bounds.y, .width = icon_width, .height = row.bounds.height }, .{ .text = "›", .face = .sans, .size = .body, .color = palette.subtext0 });
}
