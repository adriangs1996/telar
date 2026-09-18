const std = @import("std");
const Canvas = @import("Canvas.zig");
const Rect = @import("../render/Rect.zig");
const Target = @import("interaction/Target.zig");
const Widget = @This();

bounds: Rect,
thread: @import("telar-client").ThreadView,
index: u8,

/// Keeps opening the preview separate from removing the attachment.
/// Example: `try thumbnail.draw(canvas);`
pub fn draw(widget: Widget, canvas: *Canvas) !void {
    const images = widget.thread.composer_images orelse return;
    const request = @import("interaction/ImagePreview.zig").requestFor(.{
        .pane_id = widget.thread.pane_id,
        .generation = widget.thread.attachment_generation,
        .path = images.path(widget.index),
    });
    const view: @import("../diagrams/view.zig").View = if (canvas.diagrams) |store| store.request(request) else .{ .failed = .unavailable };
    const area = widget.bounds;
    const palette = canvas.theme.palette;
    try canvas.fillRoundedAt(area, .{ .color = palette.surface0, .radius = canvas.chrome.px(8) });
    switch (view) {
        .ready => |ready| try canvas.diagramAt(@import("interaction/ImagePreview.zig").fit(area, .{ ready.width, ready.height }), ready.slot),
        else => {
            var storage: [32]u8 = undefined;
            _ = try canvas.textAt(area, .{ .text = try std.fmt.bufPrint(&storage, "Image {d}", .{widget.index + 1}), .face = .sans, .size = .small, .color = palette.subtext0 });
        },
    }
    try canvas.ringAt(area, .{ .color = palette.overlay0, .radius = canvas.chrome.px(8), .width = 1, .alpha = 0.5 });
    const side = @min(canvas.chrome.px(22), @min(area.width, area.height) * 0.45);
    const remove: Rect = .{ .x = area.x + area.width - side, .y = area.y, .width = side, .height = side };
    try canvas.fillRoundedAt(remove, .{ .color = palette.surface_dim, .radius = canvas.chrome.px(6) });
    try canvas.iconAt(remove, .{ .text = "\u{f00d}", .size = .small, .color = palette.text });
    if (canvas.widgets) |state| {
        const control: @import("interaction/AgentControl.zig") = .{ .pane_id = widget.thread.pane_id, .kind = .preview_image, .image_index = widget.index, .composer_revision = widget.thread.composer_revision };
        var storage: [32]u8 = undefined;
        _ = try state.dispatcher.add((Target{ .id = .{ .generation = widget.thread.attachment_generation }, .bounds = area, .action = .{ .agent_control = control } }).labelled(try std.fmt.bufPrint(&storage, "Preview image {d}", .{widget.index + 1})));
        var removal = control;
        removal.kind = .remove_image;
        _ = try state.dispatcher.add((Target{ .id = .{ .generation = widget.thread.attachment_generation }, .bounds = remove, .action = .{ .agent_control = removal } }).labelled(try std.fmt.bufPrint(&storage, "Remove image {d}", .{widget.index + 1})));
    }
}
