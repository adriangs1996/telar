//! Cell fallback, hit targets, and KGP placement plan for local image pastes.

const std = @import("std");
const attachments = @import("../attachments/root.zig");
const widget = @import("context.zig");
const ui = @import("../ui/root.zig");

const card_width: u16 = 18;
const card_gap: u16 = 1;
const modal_max_width: u16 = 80;
const modal_max_height: u16 = 28;

pub fn renderShelf(
    context: *widget.Context,
    area: ui.Rect,
    snapshot: *const attachments.Snapshot,
) attachments.Plan {
    var plan: attachments.Plan = .{};
    if (area.isEmpty() or snapshot.len == 0) return plan;
    const style: ui.Style = .{ .fg = context.palette.text, .bg = context.palette.surface0 };
    context.buffer.fill(area, " ", style);
    const inner = area.inner(1);
    if (inner.isEmpty()) return plan;
    const gaps = @as(u16, snapshot.len - 1) * card_gap;
    const width = @min(card_width, (inner.w -| gaps) / snapshot.len);
    if (width == 0) return plan;

    for (snapshot.slice(), 0..) |item, index| {
        const card: ui.Rect = .{
            .x = inner.x + @as(u16, @intCast(index)) * (width + card_gap),
            .y = inner.y,
            .w = width,
            .h = inner.h,
        };
        const open: widget.Action = .{ .attachment_open = item.id };
        const hovered = context.isHovered(open);
        const background = if (hovered) context.palette.surface1 else context.palette.surface0;
        const card_style: ui.Style = .{ .fg = context.palette.accent, .bg = background };
        context.buffer.fill(card, " ", .{ .fg = context.palette.text, .bg = background });
        context.buffer.box(card, card_style, null);
        context.hits.add(card, open);
        if (card.w >= 4) {
            const close: ui.Rect = .{ .x = card.x + card.w - 2, .y = card.y, .w = 1, .h = 1 };
            const dismiss: widget.Action = .{ .attachment_dismiss = item.id };
            context.hits.add(close, dismiss);
            _ = context.buffer.writeText(close, close.x, close.y, "×", .{
                .fg = if (context.isHovered(dismiss)) context.palette.red else context.palette.subtext0,
                .bg = background,
            });
        }
        const image_area = card.inner(1);
        if (!image_area.isEmpty()) {
            const label = if (index == 0) "▧ image 1" else switch (index) {
                1 => "▧ image 2",
                2 => "▧ image 3",
                else => "▧ image 4",
            };
            _ = context.buffer.writeTruncated(
                image_area.row(image_area.h / 2),
                image_area.x,
                image_area.y + image_area.h / 2,
                label,
                image_area.w,
                .{ .fg = context.palette.subtext0, .bg = background },
            );
            plan.thumbnails[plan.thumbnail_count] = .{ .id = item.id, .area = image_area };
            plan.thumbnail_count += 1;
        }
    }
    return plan;
}

pub fn modalArea(workbench: ui.Rect) ui.Rect {
    if (workbench.w < 12 or workbench.h < 6) return .{};
    const width = @min(modal_max_width, workbench.w -| 4);
    const height = @min(modal_max_height, workbench.h -| 2);
    return .{
        .x = workbench.x + (workbench.w - width) / 2,
        .y = workbench.y + (workbench.h - height) / 2,
        .w = width,
        .h = height,
    };
}

pub fn renderModal(
    context: *widget.Context,
    workbench: ui.Rect,
    snapshot: *const attachments.Snapshot,
    plan: *attachments.Plan,
) ui.Rect {
    const id = snapshot.modal orelse return .{};
    const area = modalArea(workbench);
    if (area.isEmpty()) return .{};
    context.hits.beginLayer(context.buffer.area());
    defer context.hits.endLayer();
    context.hits.add(context.buffer.area(), .attachment_modal_close);
    context.hits.add(area, .attachment_modal_hold);

    const style: ui.Style = .{ .fg = context.palette.text, .bg = context.palette.surface0 };
    context.buffer.fill(area, " ", style);
    context.buffer.box(area, .{
        .fg = context.palette.accent,
        .bg = context.palette.surface0,
        .flags = .{ .bold = true },
    }, "Image preview");
    const close: ui.Rect = .{ .x = area.x + area.w - 3, .y = area.y, .w = 2, .h = 1 };
    context.hits.add(close, .attachment_modal_close);
    _ = context.buffer.writeText(close, close.x, close.y, "× ", .{
        .fg = context.palette.subtext0,
        .bg = context.palette.surface0,
    });
    const image_area = area.inner(2);
    if (!image_area.isEmpty()) {
        _ = context.buffer.writeTruncated(
            image_area.row(image_area.h / 2),
            image_area.x,
            image_area.y + image_area.h / 2,
            "Kitty graphics unavailable — press Esc to close",
            image_area.w,
            .{ .fg = context.palette.subtext0, .bg = context.palette.surface0 },
        );
        plan.modal = .{ .id = id, .area = image_area };
    }
    return area;
}

test "shelf publishes one bounded image placement and two hit targets" {
    var buffer = try ui.Buffer.init(std.testing.allocator, 40, 8);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var context: widget.Context = .{
        .buffer = &buffer,
        .hits = &hits,
        .palette = &@import("../ui/theme.zig").default_theme.palette,
        .hovered = null,
    };
    var snapshot: attachments.Snapshot = .{ .len = 1 };
    snapshot.items[0] = .{ .id = @enumFromInt(1), .width = 20, .height = 10 };
    const plan = renderShelf(&context, buffer.area(), &snapshot);
    try std.testing.expectEqual(@as(u8, 1), plan.thumbnail_count);
    try std.testing.expect(hits.len >= 2);
}
