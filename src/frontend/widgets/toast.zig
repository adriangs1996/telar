//! Toast overlay rendering for the client notification center.

const notifications = @import("../notifications/root.zig");
const widget = @import("context.zig");
const ui = @import("../ui/root.zig");

pub const card_height: u16 = 4;
pub const card_gap: u16 = 1;
pub const max_width: u16 = 48;

pub fn overlayArea(workbench: ui.Rect) ui.Rect {
    if (workbench.w < 12 or workbench.h < card_height) {
        return .{};
    }
    const horizontal_margin: u16 = @intFromBool(workbench.w > 16);
    const vertical_margin: u16 = @intFromBool(workbench.h > card_height);
    const available_width = workbench.w -| horizontal_margin * 2;
    const available_height = workbench.h -| vertical_margin;
    const height = @min(
        available_height,
        @as(u16, notifications.max_items) * (card_height + card_gap) - card_gap,
    );
    const width = @min(max_width, available_width);
    return .{
        .x = workbench.x + workbench.w - horizontal_margin - width,
        .y = workbench.y + vertical_margin,
        .w = width,
        .h = height,
    };
}

pub fn render(context: *widget.Context, area: ui.Rect, center: *const notifications.Center) void {
    renderMode(context, area, center, true);
}

/// Keeps the cell-aligned semantic targets when KGP owns the pixels.
pub fn registerHits(context: *widget.Context, area: ui.Rect, center: *const notifications.Center) void {
    renderMode(context, area, center, false);
}

fn renderMode(context: *widget.Context, area: ui.Rect, center: *const notifications.Center, paint: bool) void {
    if (area.isEmpty() or !center.hasItems()) {
        return;
    }
    context.hits.beginLayer(null);
    defer context.hits.endLayer();

    const visible_count = @min(
        @as(usize, center.count),
        @as(usize, (area.h + card_gap) / (card_height + card_gap)),
    );
    for (0..visible_count) |index| {
        const item = center.itemAt(index).?;
        const visible_width = item.animatedWidth(area.w);
        const card: ui.Rect = .{
            .x = area.x + area.w - visible_width,
            .y = area.y + @as(u16, @intCast(index)) * (card_height + card_gap),
            .w = visible_width,
            .h = card_height,
        };
        drawCard(context, card, item, paint);
    }
}

fn drawCard(context: *widget.Context, card: ui.Rect, item: *const notifications.Item, paint: bool) void {
    if (card.isEmpty()) {
        return;
    }
    const activate: widget.Action = .{ .notification_activate = item.id };
    context.hits.add(card, activate);

    if (card.w >= 12) {
        const dismiss: widget.Action = .{ .notification_dismiss = item.id };
        context.hits.add(.{
            .x = card.x + card.w - 3,
            .y = card.y,
            .w = 2,
            .h = 1,
        }, dismiss);
    }
    if (!paint) {
        return;
    }

    const accent = levelColor(context, item.level);
    const hovered = context.isHovered(activate);
    const background = if (hovered) context.palette.surface1 else context.palette.surface0;
    const body_style: ui.Style = .{ .fg = context.palette.text, .bg = background };
    const border_style: ui.Style = .{
        .fg = accent,
        .bg = background,
        .flags = .{ .bold = true },
    };
    context.buffer.fill(card, .{ .glyph = " ", .style = body_style });
    context.buffer.box(card, .{ .style = border_style, .title = if (card.w >= 12) item.title() else null });

    if (card.w < 8) {
        return;
    }
    const content: ui.Rect = .{
        .x = card.x + 2,
        .y = card.y + 1,
        .w = card.w -| 4,
        .h = 2,
    };
    _ = context.buffer.writeTruncated(content.row(0), .{ .point = .{ .x = content.x, .y = content.y }, .text = item.message(), .max_width = content.w, .style = body_style });
    const hint = if (item.clickable()) "click to open" else "click to dismiss";
    _ = context.buffer.writeTruncated(content.row(1), .{ .point = .{ .x = content.x, .y = content.y + 1 }, .text = hint, .max_width = content.w, .style = .{
        .fg = if (hovered) accent else context.palette.subtext0,
        .bg = background,
        .flags = .{ .underline = if (hovered) .single else .none },
    } });

    if (card.w >= 12) {
        const dismiss: widget.Action = .{ .notification_dismiss = item.id };
        const close: ui.Rect = .{
            .x = card.x + card.w - 3,
            .y = card.y,
            .w = 2,
            .h = 1,
        };
        _ = context.drawIcon(.{
            .area = close,
            .point = .{ .x = close.x, .y = close.y },
            .icon = .close,
            .style = .{
                .fg = if (context.isHovered(dismiss)) context.palette.text else accent,
                .bg = background,
                .flags = .{ .bold = true },
            },
        });
    }
}

fn levelColor(context: *const widget.Context, level: notifications.Level) ui.Color {
    return switch (level) {
        .info => context.palette.blue,
        .success => context.palette.green,
        .warning => context.palette.yellow,
        .failure => context.palette.red,
    };
}

test "toast cards register activation and a separate close target" {
    const std = @import("std");
    const theme = ui.theme;
    var buffer = try ui.Buffer.init(std.testing.allocator, 80, 24);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var center: notifications.Center = .{};
    const id = center.push(0, .{
        .title = "Build complete",
        .message = "Open the result",
        .target = .{ .select_tab = @enumFromInt(7) },
    });
    _ = center.advance(notifications.transition_duration_ns);
    var context: widget.Context = .{
        .buffer = &buffer,
        .hits = &hits,
        .palette = &theme.default_theme.palette,
        .hovered = null,
    };

    const area = overlayArea(.{ .w = 80, .h = 24 });
    render(&context, area, &center);
    try std.testing.expectEqual(
        widget.Action{ .notification_activate = id },
        hits.at(area.x, area.y).?,
    );
    try std.testing.expectEqual(
        widget.Action{ .notification_dismiss = id },
        hits.at(area.x + area.w - 2, area.y).?,
    );
}
