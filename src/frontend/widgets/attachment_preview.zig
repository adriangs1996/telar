//! Cell fallback, hit targets, and KGP placement plan for local image pastes.

const std = @import("std");
const attachments = @import("../attachments/root.zig");
const modal = @import("modal.zig");
const widget = @import("context.zig");
const ui = @import("../ui/root.zig");

const card_width: u16 = 18;
const card_gap: u16 = 1;
pub const shelf_height: u16 = 6;
pub const shelf_minimum_height: u16 = 3;
pub const pane_minimum_height: u16 = 3;

pub fn renderShelf(context: *widget.Context, area: ui.Rect, snapshot: *const attachments.Snapshot) attachments.Plan {
    var plan: attachments.Plan = .{};
    if (area.isEmpty() or snapshot.len == 0) {
        return plan;
    }
    const style: ui.Style = .{ .fg = context.palette.text, .bg = context.palette.surface0 };
    context.hits.add(area, .attachment_shelf_hold);
    context.buffer.fill(area, .{ .glyph = " ", .style = style });
    const inner = area.inner(1);
    if (inner.isEmpty()) {
        return plan;
    }
    const gaps = @as(u16, snapshot.len - 1) * card_gap;
    const width = @min(card_width, (inner.w -| gaps) / snapshot.len);
    if (width == 0) {
        return plan;
    }

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
        context.buffer.fill(card, .{ .glyph = " ", .style = .{ .fg = context.palette.text, .bg = background } });
        context.buffer.box(card, .{ .style = card_style });
        context.hits.add(card, open);
        if (card.w >= 4) {
            const close: ui.Rect = .{ .x = card.x + card.w - 2, .y = card.y, .w = 1, .h = 1 };
            const dismiss: widget.Action = .{ .attachment_dismiss = item.id };
            context.hits.add(close, dismiss);
            _ = context.buffer.writeText(close, .{ .point = .{ .x = close.x, .y = close.y }, .text = "×", .style = .{
                .fg = if (context.isHovered(dismiss)) context.palette.red else context.palette.subtext0,
                .bg = background,
            } });
        }
        const image_area = card.inner(1);
        if (!image_area.isEmpty()) {
            const label = if (index == 0) "▧ image 1" else switch (index) {
                1 => "▧ image 2",
                2 => "▧ image 3",
                else => "▧ image 4",
            };
            _ = context.buffer.writeTruncated(image_area.row(image_area.h / 2), .{ .point = .{ .x = image_area.x, .y = image_area.y + image_area.h / 2 }, .text = label, .max_width = image_area.w, .style = .{ .fg = context.palette.subtext0, .bg = background } });
            plan.thumbnails[plan.thumbnail_count] = .{ .id = item.id, .area = image_area };
            plan.thumbnail_count += 1;
        }
    }
    return plan;
}

/// Uses the shared application-level modal geometry when the terminal can fit
/// the preview controls.
///
/// ```zig
/// const area = modalArea(context.buffer.area());
/// ```
pub fn modalArea(application: ui.Rect) ui.Rect {
    if (application.w < 12 or application.h < 6) {
        return .{};
    }

    return modal.area(application);
}

pub const ModalInput = struct {
    application: ui.Rect,
    snapshot: *const attachments.Snapshot,
    plan: *attachments.Plan,
    graphical_frame: bool,
};

/// Draws the image preview and publishes its graphics placement.
///
/// ```zig
/// const area = renderModal(context, input);
/// ```
pub fn renderModal(context: *widget.Context, input: ModalInput) ui.Rect {
    const id = input.snapshot.modal orelse return .{};
    const area = modalArea(input.application);
    if (area.isEmpty()) {
        return .{};
    }

    context.hits.beginLayer(context.buffer.area());
    defer context.hits.endLayer();
    context.hits.add(context.buffer.area(), .attachment_modal_close);
    context.hits.add(area, .attachment_modal_hold);

    const background = context.palette.panel_bg;
    const style: ui.Style = .{ .fg = context.palette.text, .bg = background };
    const border_style: ui.Style = .{
        .fg = context.palette.accent,
        .bg = background,
    };
    if (input.graphical_frame) {
        context.buffer.fillWithoutCorners(area, style);
    } else {
        context.buffer.fill(area, .{ .glyph = " ", .style = style });
        context.buffer.box(area, .{ .style = border_style });
    }
    const title: ui.Rect = .{ .x = area.x + 2, .y = area.y, .w = area.w -| 6, .h = 1 };
    _ = context.buffer.writeTruncated(title, .{ .point = .{ .x = title.x, .y = title.y }, .text = "Image preview", .max_width = title.w, .style = .{
        .fg = context.palette.accent,
        .bg = background,
    } });
    const close: ui.Rect = .{ .x = area.x + area.w - 3, .y = area.y, .w = 2, .h = 1 };
    context.hits.add(close, .attachment_modal_close);
    _ = context.buffer.writeText(close, .{ .point = .{ .x = close.x, .y = close.y }, .text = "× ", .style = .{
        .fg = context.palette.subtext0,
        .bg = background,
    } });
    const image_area = area.inner(2);
    if (!image_area.isEmpty()) {
        _ = context.buffer.writeTruncated(image_area.row(image_area.h / 2), .{ .point = .{ .x = image_area.x, .y = image_area.y + image_area.h / 2 }, .text = "Kitty graphics unavailable — press Esc to close", .max_width = image_area.w, .style = .{ .fg = context.palette.subtext0, .bg = background } });
        input.plan.modal = .{ .id = id, .area = image_area };
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

test "cell modal draws a connected border" {
    var buffer = try ui.Buffer.init(std.testing.allocator, 40, 10);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    const palette = &@import("../ui/theme.zig").default_theme.palette;
    var context: widget.Context = .{
        .buffer = &buffer,
        .hits = &hits,
        .palette = palette,
        .hovered = null,
    };
    const id: attachments.Id = @enumFromInt(1);
    const snapshot: attachments.Snapshot = .{ .modal = id };
    var plan: attachments.Plan = .{};

    const area = renderModal(&context, .{
        .application = buffer.area(),
        .snapshot = &snapshot,
        .plan = &plan,
        .graphical_frame = false,
    });

    try std.testing.expect(!area.isEmpty());
    try std.testing.expectEqualStrings("╭", buffer.at(area.x, area.y).?.text());
    try std.testing.expectEqualStrings("╮", buffer.at(area.x + area.w - 1, area.y).?.text());
    try std.testing.expectEqualStrings("╰", buffer.at(area.x, area.y + area.h - 1).?.text());
    try std.testing.expectEqualStrings("╯", buffer.at(area.x + area.w - 1, area.y + area.h - 1).?.text());
    try std.testing.expectEqualStrings("│", buffer.at(area.x, area.y + 1).?.text());
    try std.testing.expectEqualStrings("│", buffer.at(area.x + area.w - 1, area.y + 1).?.text());
    try std.testing.expectEqualStrings("─", buffer.at(area.x + 1, area.y).?.text());
    try std.testing.expectEqualStrings("─", buffer.at(area.x + 1, area.y + area.h - 1).?.text());
    try std.testing.expectEqualDeep(palette.panel_bg, buffer.at(area.x, area.y + 1).?.style.bg);
    try std.testing.expect(std.meta.eql(buffer.at(area.x - 1, area.y + 1).?.style.bg, ui.Color.default));
}

test "graphical modal leaves corner cells to its rounded frame" {
    var buffer = try ui.Buffer.init(std.testing.allocator, 40, 10);
    defer buffer.deinit();
    buffer.fill(buffer.area(), .{ .glyph = ".", .style = .{} });
    var hits: widget.Hits = .{};
    const palette = &@import("../ui/theme.zig").default_theme.palette;
    var context: widget.Context = .{
        .buffer = &buffer,
        .hits = &hits,
        .palette = palette,
        .hovered = null,
    };
    const snapshot: attachments.Snapshot = .{ .modal = @enumFromInt(1) };
    var plan: attachments.Plan = .{};

    const area = renderModal(&context, .{
        .application = buffer.area(),
        .snapshot = &snapshot,
        .plan = &plan,
        .graphical_frame = true,
    });

    try std.testing.expectEqualStrings(".", buffer.at(area.x, area.y).?.text());
    try std.testing.expectEqualStrings(".", buffer.at(area.x + area.w - 1, area.y).?.text());
    try std.testing.expectEqualDeep(palette.panel_bg, buffer.at(area.x + 1, area.y).?.style.bg);
}
