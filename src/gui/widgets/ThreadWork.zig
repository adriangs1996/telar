//! One disclosure for the work between a prompt and its final response.
const std = @import("std");
const Canvas = @import("Canvas.zig");
const Work = @This();

view: @import("ThreadItemView.zig"),

/// Example: `const height = ThreadWork.measure(canvas);`
pub fn measure(canvas: *const Canvas) f32 {
    return canvas.chrome.px(40);
}

/// The whole row is a keyboard-accessible disclosure; hidden work paints nothing.
/// Example: `try work.draw(canvas);`
pub fn draw(work: Work, canvas: *Canvas) !void {
    const view = work.view;
    const palette = canvas.theme.palette;
    const side = canvas.chrome.px(16);
    const gap = canvas.chrome.px(8);
    const row = canvas.chrome.px(32);
    const icon_width = @min(side, view.bounds.width);
    try canvas.iconAt(.{ .x = view.bounds.x, .y = view.bounds.y + (row - side) / 2, .width = icon_width, .height = side }, .{ .text = if (view.expanded) "\u{f078}" else "\u{f054}", .face = .sans, .size = .small, .color = palette.overlay1 });
    var storage: [96]u8 = undefined;
    const text = try std.fmt.bufPrint(&storage, "{s} · {d} {s}", .{ if (view.work_active) @as([]const u8, "Working") else "Agent work", view.work_count, if (view.work_count == 1) @as([]const u8, "activity") else "activities" });
    const bounds: @import("../render/Rect.zig") = .{ .x = view.bounds.x + icon_width + gap, .y = view.bounds.y, .width = @max(0, view.bounds.width - icon_width - gap), .height = row };
    var fitted: [@import("TextFit.zig").max_bytes]u8 = undefined;
    var label: @import("Label.zig") = .{ .text = text, .face = .sans, .size = .small, .color = palette.subtext0 };
    label.text = try (@import("TextFit.zig"){ .canvas = canvas, .width = bounds.width }).fit(label, &fitted);
    try (@import("ActivityText.zig"){ .bounds = bounds, .label = label, .active = view.work_active }).draw(canvas);
    try (@import("ThreadItemButton.zig"){ .bounds = view.bounds, .viewport = view.viewport, .control = view.control(), .label = if (view.expanded) "Hide agent work" else "Show agent work" }).register(canvas);
}
