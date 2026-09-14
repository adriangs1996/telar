//! One native card. Text and semantic state are borrowed only while drawing.
const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const Canvas = @import("../Canvas.zig");
const Rect = @import("../../render/Rect.zig");
const Label = @import("../Label.zig");
const TextFit = @import("../TextFit.zig");
const Target = @import("../interaction/Target.zig");
const Hits = @import("NotificationHits.zig");
const Text = @import("NotificationText.zig");
const Card = @This();

item: *const client.NotificationItem,
bounds: Rect,
body: Text = .{},
opacity: f32 = 1,
clip: Rect,
hits: ?*Hits = null,

/// Measures the body once so drawing and input share the same pixel layout.
/// Example: `try card.measure(canvas);`
pub fn measure(card: *Card, canvas: *Canvas) !void {
    const text_width = card.bounds.width - canvas.chrome.px(76);
    try card.body.wrap(canvas, .{ .text = card.item.message(), .width = text_width });
    card.bounds.height = canvas.chrome.px(28) + canvas.chrome.rowHeight(.title);
    if (card.body.count > 0) {
        card.bounds.height += canvas.chrome.px(4) + @as(f32, @floatFromInt(card.body.count)) * canvas.chrome.rowHeight(.body);
    }
    if (card.item.clickable()) {
        card.bounds.height += canvas.chrome.px(10) + canvas.chrome.rowHeight(.small);
    }

    card.bounds.height = @max(card.bounds.height, canvas.chrome.px(64));
}

/// Paints and registers exactly the same bounds, with the close control last.
/// Example: `try card.draw(canvas);`
pub fn draw(card: *const Card, canvas: *Canvas) !void {
    const first = canvas.quads.items().len;
    const palette = canvas.theme.palette;
    const px = canvas.chrome;
    const bounds = card.bounds;
    const radius = px.px(12);
    const accent = card.accentColor(canvas);
    for (0..3) |layer| {
        const spread = px.px(@as(f32, @floatFromInt(3 - layer)) * 2);
        try canvas.quads.pushRounded(.{ .x = bounds.x - spread, .y = bounds.y - spread + px.px(3), .width = bounds.width + 2 * spread, .height = bounds.height + 2 * spread }, .{ .fill = .{ .r = 0, .g = 0, .b = 0, .a = 0.055 }, .radius = radius + spread });
    }

    try canvas.fillRoundedAt(bounds, .{ .color = canvas.covering(palette.surface0), .radius = radius });
    try canvas.ringAt(bounds, .{ .color = palette.overlay0, .width = px.px(1), .radius = radius, .alpha = 0.35 });

    var target = (Target{ .bounds = bounds, .action = .{ .intent = .{ .notification_activate = card.item.id } }, .enabled = card.item.phase != .exiting }).labelled(card.item.title());
    if (!card.item.clickable()) {
        target.action = .{ .intent = .{ .notification_dismiss = card.item.id } };
    }
    // Body and close can share a dismiss action, so use distinct namespaces.
    target.namespace = 2;
    var accessible: [128]u8 = undefined;
    const label = std.fmt.bufPrint(&accessible, "{s}: {s}", .{ card.item.title(), card.item.message() }) catch card.item.title();
    target = target.labelled(label);
    if (card.focused(canvas, target)) {
        try canvas.ringAt(bounds, .{ .color = accent, .width = px.px(1.5), .radius = radius });
    }
    card.register(target);

    const icon: Rect = .{ .x = bounds.x + px.px(14), .y = bounds.y + px.px(14), .width = px.px(28), .height = px.px(28) };
    const icon_start = canvas.quads.items().len;
    try canvas.fillRoundedAt(icon, .{ .color = accent, .radius = px.px(9) });
    canvas.quads.fadeFrom(icon_start, 0.14);
    const symbol: Label = .{ .text = switch (card.item.level) {
        .info => "i",
        .success => "\u{2713}",
        .warning => "!",
        .failure => "\u{00d7}",
    }, .color = accent, .face = .sans, .size = .title, .bold = true };
    const symbol_width = try canvas.measure(symbol);
    _ = try canvas.textAt(.{ .x = icon.x + (icon.width - symbol_width) / 2, .y = icon.y, .width = symbol_width, .height = icon.height }, symbol);

    const text_x = bounds.x + px.px(54);
    var title: Label = .{ .text = card.item.title(), .color = palette.text, .face = .sans, .size = .title, .bold = true };
    var title_buffer: [TextFit.max_bytes]u8 = undefined;
    const title_width = bounds.width - px.px(94);
    title.text = try (TextFit{ .canvas = canvas, .width = title_width }).fit(title, &title_buffer);
    _ = try canvas.textAt(.{ .x = text_x, .y = bounds.y + px.px(14), .width = title_width, .height = px.rowHeight(.title) }, title);
    var y = bounds.y + px.px(18) + px.rowHeight(.title);
    for (0..card.body.count) |index| {
        _ = try canvas.textAt(.{ .x = text_x, .y = y, .width = bounds.width - px.px(76), .height = px.rowHeight(.body) }, .{ .text = card.body.line(index), .color = palette.subtext0, .face = .sans, .size = .body });
        y += px.rowHeight(.body);
    }

    if (card.item.clickable()) {
        const action: Label = .{ .text = switch (card.item.target) {
            .focus_pane => "Open pane \u{2192}",
            .select_tab => "Open tab \u{2192}",
            .select_workspace => "Open workspace \u{2192}",
            .none => unreachable,
        }, .color = accent, .face = .sans, .size = .small, .bold = true, .underline = card.hovered(canvas, target) };
        _ = try canvas.textAt(.{ .x = text_x, .y = bounds.y + bounds.height - px.px(14) - px.rowHeight(.small), .width = bounds.width - px.px(76), .height = px.rowHeight(.small) }, action);
    }

    const close: Rect = .{ .x = bounds.x + bounds.width - px.px(34), .y = bounds.y + px.px(8), .width = px.px(26), .height = px.px(26) };
    const dismiss = (Target{ .bounds = close, .action = .{ .intent = .{ .notification_dismiss = card.item.id } }, .namespace = 3, .enabled = target.enabled }).labelled("Dismiss notification");
    if (card.hovered(canvas, dismiss) or card.focused(canvas, dismiss)) {
        try canvas.fillRoundedAt(close, .{ .color = palette.surface1, .radius = px.px(7) });
    }
    if (card.focused(canvas, dismiss)) {
        try canvas.ringAt(close, .{ .color = accent, .width = px.px(1), .radius = px.px(7) });
    }

    const cross: Label = .{ .text = "\u{00d7}", .color = palette.subtext0, .face = .sans, .size = .title };
    const cross_width = try canvas.measure(cross);
    _ = try canvas.textAt(.{ .x = close.x + (close.width - cross_width) / 2, .y = close.y, .width = cross_width, .height = close.height }, cross);
    card.register(dismiss);
    canvas.quads.fadeFrom(first, card.opacity);
    canvas.quads.clipFrom(first, card.clip);
}

fn register(card: *const Card, value: Target) void {
    const hits = card.hits orelse return;
    var target = value;
    const host = card.clip;
    const bounds = target.bounds;
    const x = @max(bounds.x, host.x);
    const y = @max(bounds.y, host.y);
    target.bounds = .{ .x = x, .y = y, .width = @max(0, @min(bounds.x + bounds.width, host.x + host.width) - x), .height = @max(0, @min(bounds.y + bounds.height, host.y + host.height) - y) };
    hits.hits[hits.count] = target;
    hits.count += 1;
}

fn accentColor(card: *const Card, canvas: *const Canvas) core.Color {
    return switch (card.item.level) {
        .info => canvas.theme.palette.blue,
        .success => canvas.theme.palette.green,
        .warning => canvas.theme.palette.yellow,
        .failure => canvas.theme.palette.red,
    };
}

fn hovered(_: *const Card, canvas: *const Canvas, target: Target) bool {
    const widgets = canvas.widgets orelse return false;
    const id = widgets.dispatcher.hovered orelse return false;
    const previous = widgets.dispatcher.maps.presented().find(id) orelse return false;
    return previous.namespace == target.namespace and std.meta.eql(previous.action, target.action);
}

fn focused(_: *const Card, canvas: *const Canvas, target: Target) bool {
    const widgets = canvas.widgets orelse return false;
    const previous = widgets.dispatcher.focusedTarget() orelse return false;
    return previous.namespace == target.namespace and std.meta.eql(previous.action, target.action);
}
