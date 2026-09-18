const std = @import("std");
const Canvas = @import("../Canvas.zig");
const Rect = @import("../../render/Rect.zig");
const Preview = @import("../interaction/ImagePreview.zig");
const Target = @import("../interaction/Target.zig");
const Widget = @This();

preview: *const Preview,

/// Paints above pane clipping only while the prepared frame retains the draft.
/// Example: `try ImagePreview.drawCurrent(canvas);`
pub fn drawCurrent(canvas: *Canvas) !void {
    const state = canvas.widgets orelse return;
    const preview = if (state.image_preview) |*value| value else return;
    const registry = state.dispatcher.maps.preparing();
    var found = false;
    for (registry.targets[0..registry.len]) |target| {
        if (preview.matches(target)) {
            found = true;
            break;
        }
    }

    if (!found or registry.modal_layer != 0) {
        state.image_preview = null;
        return;
    }

    registry.modal_layer = 1;
    try (Widget{ .preview = preview }).draw(canvas);
}

/// Example: `try preview_overlay.draw(canvas);`
pub fn draw(widget: Widget, canvas: *Canvas) !void {
    const preview = widget.preview;
    const state = canvas.widgets orelse return;
    const window: Rect = .{ .x = 0, .y = 0, .width = @floatFromInt(canvas.viewport[0]), .height = @floatFromInt(canvas.viewport[1]) };
    const margin = @min(canvas.chrome.px(36), @min(window.width, window.height) / 12);
    const area: Rect = .{ .x = margin, .y = margin, .width = @max(0, window.width - 2 * margin), .height = @max(0, window.height - 2 * margin) };
    try canvas.dimAt(window, 0.85);
    try canvas.fillRoundedAt(area, .{ .color = canvas.theme.palette.surface_dim, .radius = canvas.chrome.px(12) });
    var close = preview.control;
    close.kind = .close_image;
    _ = try state.dispatcher.add((Target{ .id = .{ .generation = preview.generation }, .namespace = 1, .bounds = window, .action = .{ .agent_control = close }, .layer = 1, .focusable = false }).labelled("Close image preview"));
    _ = try state.dispatcher.add(.{ .id = .{ .generation = preview.generation }, .namespace = 2, .bounds = area, .action = .{ .custom = 0 }, .layer = 1, .focusable = false });
    const header = @min(canvas.chrome.px(40), area.height / 5);
    const content: Rect = .{ .x = area.x + margin / 2, .y = area.y + header, .width = @max(0, area.width - margin), .height = @max(0, area.height - header - margin / 2) };
    const request = Preview.requestFor(.{ .pane_id = preview.control.pane_id, .generation = preview.generation, .path = preview.path() });
    const view: @import("../../diagrams/view.zig").View = if (canvas.diagrams) |store| store.request(request) else .{ .failed = .unavailable };
    switch (view) {
        .ready => |ready| try canvas.diagramAt(Preview.fit(content, .{ ready.width, ready.height }), ready.slot),
        else => _ = try canvas.textAt(content, .{ .text = if (view == .pending) "Loading image…" else "Image preview unavailable", .face = .sans, .size = .body, .color = canvas.theme.palette.subtext0 }),
    }

    var storage: [32]u8 = undefined;
    _ = try canvas.textAt(.{ .x = content.x, .y = area.y, .width = @max(0, content.width - header), .height = header }, .{ .text = try std.fmt.bufPrint(&storage, "Image {d}", .{preview.control.image_index + 1}), .face = .sans, .size = .small, .color = canvas.theme.palette.subtext0 });
    const button: Rect = .{ .x = area.x + area.width - header, .y = area.y, .width = header, .height = header };
    try canvas.iconAt(button, .{ .text = "\u{f00d}", .size = .body, .color = canvas.theme.palette.text });
    _ = try state.dispatcher.add((Target{ .id = .{ .generation = preview.generation }, .bounds = button, .action = .{ .agent_control = close }, .layer = 1 }).labelled("Close image preview"));
}
