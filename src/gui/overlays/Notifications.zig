const core = @import("telar-core");
const client = @import("telar-client");
const Canvas = @import("../chrome/Canvas.zig");
const OverlayHit = @import("OverlayHit.zig");
const Notifications = @This();

hits: [client.max_items * 2]OverlayHit = undefined,
count: usize = 0,

/// Rebuilds a bounded hit map from exactly the cards painted in this frame.
/// Example: `try notifications.paint(canvas, projection);`.
pub fn paint(notifications: *Notifications, canvas: *Canvas, projection: client.Projection) !void {
    notifications.count = 0;
    const host = projection.geometry.area;
    if (host.w < 12 or host.h < 4) {
        return;
    }

    const palette = canvas.theme.palette;
    const width = @min(@as(u16, 48), host.w -| 2);
    const cards = @min(projection.notifications.count, (host.h -| 1) / 5);
    for (0..cards) |index| {
        const item = projection.notifications.itemAt(index).?;
        const visible = item.animatedWidth(width);
        if (visible == 0) {
            continue;
        }

        const card: core.Rect = .{ .x = host.x + host.w - 1 - visible, .y = host.y + 1 + @as(u16, @intCast(index)) * 5, .w = visible, .h = 4 };
        const accent = switch (item.level) {
            .info => palette.blue,
            .success => palette.green,
            .warning => palette.yellow,
            .failure => palette.red,
        };
        notifications.add(.{ .area = card, .intent = .{ .notification_activate = item.id } });
        try canvas.fill(card, palette.surface0);
        try canvas.border(card, accent);

        if (card.w < 8) {
            continue;
        }

        try canvas.text(.{ .x = card.x + 2, .y = card.y, .w = card.w -| 6, .h = 1 }, .{ .text = item.title(), .color = accent, .bold = true });
        const content = card.inner(1);
        try canvas.text(content.row(0), .{ .text = item.message(), .color = palette.text });
        try canvas.text(content.row(1), .{ .text = if (item.clickable()) "click to open" else "click to dismiss", .color = palette.subtext0 });

        const close: core.Rect = .{ .x = card.x + card.w - 3, .y = card.y, .w = 2, .h = 1 };
        notifications.add(.{ .area = close, .intent = .{ .notification_dismiss = item.id } });
        try canvas.text(close, .{ .text = "×", .color = accent, .bold = true });
    }
}

fn add(notifications: *Notifications, hit: OverlayHit) void {
    notifications.hits[notifications.count] = hit;
    notifications.count += 1;
}

/// Resolves the topmost card control using stable notification IDs.
/// Example: `const intent = notifications.at(mouse);`.
pub fn at(notifications: *const Notifications, mouse: client.Mouse) ?client.Intent {
    var index = notifications.count;
    while (index > 0) {
        index -= 1;
        const hit = notifications.hits[index];
        if (hit.area.contains(mouse.x, mouse.y)) {
            return hit.intent;
        }
    }

    return null;
}
