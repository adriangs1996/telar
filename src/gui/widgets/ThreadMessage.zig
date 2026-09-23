//! Sent prompts and assistant prose have distinct, quiet conversation surfaces.
const std = @import("std");
const Canvas = @import("Canvas.zig");
const Rect = @import("../render/Rect.zig");
const MessageText = @import("MessageText.zig");
const Message = @This();

view: @import("ThreadItemView.zig"),

/// Measures a prompt bubble or assistant message using the paint text layout,
/// reusing the height retained for identical layout inputs.
/// Example: `const height = try message.measure(canvas);`
pub fn measure(message: Message, canvas: *Canvas) !f32 {
    const state = canvas.widgets orelse return message.measureLayout(canvas);
    const key = message.heightKey(canvas) orelse return message.measureLayout(canvas);
    const heights = try state.messageHeights(canvas.atlas.allocator);
    if (heights.find(key)) |height| {
        return height;
    }

    const height = try message.measureLayout(canvas);
    heights.remember(key, height);
    return height;
}

fn measureLayout(message: Message, canvas: *Canvas) !f32 {
    const user = message.view.item.role == .user;
    const content = message.body(canvas);
    return try content.measure(canvas) + canvas.chrome.px(if (user) @as(f32, 48) else if (message.copyable()) 78 else 50) + canvas.chrome.px(if (message.fragment()) @as(f32, 22) else 0);
}

/// Null when the height also depends on state outside the text: a Mermaid
/// block measures differently once its diagram is ready.
fn heightKey(message: Message, canvas: *const Canvas) ?@import("MessageHeightKey.zig") {
    const item = message.view.item;
    const text = message.view.text();
    if (std.mem.indexOf(u8, text, "mermaid") != null) {
        return null;
    }

    return .{
        .text_hash = std.hash.Wyhash.hash(0, text),
        .text_len = @intCast(text.len),
        .width = message.view.bounds.width,
        .font_identity = canvas.atlas.fonts.identity,
        .font_revision = canvas.atlas.fonts.revision,
        .chrome = canvas.chrome,
        .metrics = canvas.metrics,
        .role = item.role,
        .complete = item.complete,
        .identified = item.identity != 0,
        .fragment_start = item.fragment_start,
        .fragment_end = item.fragment_end,
    };
}

/// Paints sent text, structured prose, and a stable copy control after completion.
/// Example: `try message.draw(canvas);`
pub fn draw(message: Message, canvas: *Canvas) !void {
    const view = message.view;
    const palette = canvas.theme.palette;
    const content = message.body(canvas);
    const user = view.item.role == .user;
    if (user) {
        const inset = canvas.chrome.px(14);
        const area: Rect = .{ .x = content.bounds.x - inset, .y = view.bounds.y, .width = content.bounds.width + 2 * inset, .height = @max(0, view.bounds.height - canvas.chrome.px(20)) };
        try canvas.fillRoundedAt(area, .{ .color = palette.surface0, .radius = canvas.chrome.px(16) });
        try canvas.ringAt(area, .{ .color = palette.overlay0, .width = 1, .radius = canvas.chrome.px(16), .alpha = 0.3 });
    } else {
        const side = canvas.chrome.px(16);
        const icon: Rect = .{ .x = view.bounds.x, .y = view.bounds.y + canvas.chrome.px(7), .width = side, .height = side };
        if (canvas.providerMark(.codex)) |mark| {
            try canvas.spriteTintedAt(icon, .{ .sprite = mark, .color = palette.text });
        } else {
            try canvas.iconAt(icon, .{ .text = "\u{f121}", .face = .sans, .size = .body, .color = palette.subtext0 });
        }

        _ = try canvas.textAt(.{ .x = view.bounds.x + side + canvas.chrome.px(8), .y = view.bounds.y, .width = @max(0, view.bounds.width - side - canvas.chrome.px(8)), .height = canvas.chrome.px(30) }, .{ .text = "Codex", .face = .sans, .size = .small, .bold = true, .color = palette.subtext0 });
    }

    if (message.fragment()) {
        _ = try canvas.textAt(.{ .x = content.bounds.x, .y = content.bounds.y - canvas.chrome.px(22), .width = content.bounds.width, .height = canvas.chrome.px(22) }, .{ .text = "Message continues · scroll to read more", .face = .sans, .size = .small, .color = palette.overlay1 });
    }

    try content.draw(canvas);
    if (message.copyable()) {
        const area: Rect = .{ .x = view.bounds.x, .y = view.bounds.y + view.bounds.height - canvas.chrome.px(42), .width = canvas.chrome.px(28), .height = canvas.chrome.px(26) };
        var control = view.control();
        control.operation = .copy;
        const visible = area.y + area.height > view.viewport.y and area.y < view.viewport.y + view.viewport.height;
        const copied = if (canvas.widgets) |state| visible and state.threadCopied(control, canvas.animation) else false;
        try canvas.iconAt(area, .{ .text = if (copied) "\u{f00c}" else "\u{f0c5}", .face = .sans, .size = .small, .color = if (copied) palette.teal else palette.overlay1 });
        try (@import("ThreadItemButton.zig"){ .bounds = area, .viewport = view.viewport, .control = control, .label = if (message.fragment()) "Copy segment" else "Copy response" }).register(canvas);
    }
}

fn body(message: Message, canvas: *const Canvas) MessageText {
    const view = message.view;
    const user = view.item.role == .user;
    const inset = canvas.chrome.px(14);
    const width = if (user) @max(1, @min(view.bounds.width * 0.86, view.bounds.width - 2 * inset)) else view.bounds.width;
    return .{ .bounds = .{ .x = if (user) view.bounds.x + view.bounds.width - width - inset else view.bounds.x, .y = view.bounds.y + canvas.chrome.px(if (user) @as(f32, 14) else 32) + canvas.chrome.px(if (message.fragment()) @as(f32, 22) else 0), .width = width, .height = 0 }, .viewport = view.viewport, .text = view.text(), .markdown = !user and !message.fragment(), .owner = view.source(.body) };
}

fn fragment(message: Message) bool {
    return !message.view.item.fragment_start or !message.view.item.fragment_end;
}

fn copyable(message: Message) bool {
    return message.view.item.role == .assistant and message.view.item.complete and message.view.text().len > 0 and message.view.item.identity != 0;
}
