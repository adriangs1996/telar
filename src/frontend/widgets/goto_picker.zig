//! Centered goto-picker modal: one query line above a scored result list.

const std = @import("std");
const core = @import("telar-core");
const edit = @import("../input/root.zig").edit;
const widget = @import("context.zig");
const ui = @import("../ui/root.zig");

const schema = core.schema;

pub const Field = edit.Field(schema.max_tab_label_bytes);
pub const max_rows = 12;
pub const max_row_bytes = 160;
const modal_max_width: u16 = 64;

pub const Row = struct {
    text: [max_row_bytes]u8 = undefined,
    len: u8 = 0,
    selected: bool = false,

    pub fn slice(row: *const Row) []const u8 {
        return row.text[0..row.len];
    }
};

pub const Input = struct {
    title: []const u8,
    field: *Field,
    rows: []const Row,
    total: u16,
    /// Short status shown in the bottom border, e.g. the active scope.
    hint: []const u8 = "",
    /// True when a pixel-aligned frame already surrounds the modal, so the
    /// cell border must not be drawn on top of it.
    graphical_frame: bool = false,
};

pub const Output = struct {
    area: ui.Rect,
    cursor: ?widget.Cursor,
};

/// Centered rectangle sized for the query line plus the visible result rows.
///
/// ```zig
/// const area = modalArea(regions.workbench);
/// ```
pub fn modalArea(workbench: ui.Rect) ui.Rect {
    if (workbench.w < 20 or workbench.h < 6) {
        return .{};
    }

    const width = @min(modal_max_width, workbench.w -| 4);
    const height = @min(@as(u16, max_rows + 3), workbench.h -| 2);
    return .{
        .x = workbench.x + (workbench.w - width) / 2,
        .y = workbench.y + (workbench.h - height) / 2,
        .w = width,
        .h = height,
    };
}

/// Draws the picker into the workbench and returns its area with the query
/// cursor position, so the caller can synchronize the modal overlay and the
/// terminal cursor.
///
/// ```zig
/// const output = render(context, regions.workbench, picker_input);
/// ```
pub fn render(context: *widget.Context, workbench: ui.Rect, input: Input) Output {
    const area = modalArea(workbench);
    if (area.isEmpty()) {
        return .{ .area = area, .cursor = null };
    }

    const background = context.palette.panel_bg;
    const style: ui.Style = .{ .fg = context.palette.text, .bg = background };
    if (input.graphical_frame) {
        context.buffer.fillWithoutCorners(area, style);
    } else {
        context.buffer.fill(area, " ", style);
        context.buffer.box(area, .{
            .fg = context.palette.accent,
            .bg = background,
        }, null);
    }

    const title: ui.Rect = .{ .x = area.x + 2, .y = area.y, .w = area.w -| 4, .h = 1 };
    _ = context.buffer.writeTruncated(title, title.x, title.y, input.title, title.w, .{
        .fg = context.palette.accent,
        .bg = background,
        .flags = .{ .bold = true },
    });

    const inner = area.inner(1);
    const query: ui.Rect = .{ .x = inner.x, .y = inner.y, .w = inner.w, .h = 1 };
    const prefix_width = context.buffer.writeText(query, query.x, query.y, "> ", .{
        .fg = context.palette.accent,
        .bg = background,
        .flags = .{ .bold = true },
    });
    const field_width = query.w -| prefix_width;
    const view = input.field.view(field_width);
    _ = context.buffer.writeTruncated(query, query.x + prefix_width, query.y, view.text, field_width, style);

    var row_y = query.y + 1;
    for (input.rows) |*row| {
        if (row_y >= inner.y + inner.h) {
            break;
        }

        const line: ui.Rect = .{ .x = inner.x, .y = row_y, .w = inner.w, .h = 1 };
        const row_background = if (row.selected) context.palette.surface1 else background;
        context.buffer.fill(line, " ", .{ .fg = context.palette.text, .bg = row_background });
        _ = context.buffer.writeTruncated(line, line.x + 1, line.y, row.slice(), line.w -| 2, .{
            .fg = if (row.selected) context.palette.accent else context.palette.text,
            .bg = row_background,
            .flags = .{ .bold = row.selected },
        });
        row_y += 1;
    }

    var footer_storage: [48]u8 = undefined;
    const overflow = input.total -| @as(u16, @intCast(input.rows.len));
    const footer_text = if (input.hint.len != 0 and overflow != 0)
        std.fmt.bufPrint(&footer_storage, "{s}  +{d} more", .{ input.hint, overflow }) catch input.hint
    else if (input.hint.len != 0)
        input.hint
    else if (overflow != 0)
        std.fmt.bufPrint(&footer_storage, "+{d} more", .{overflow}) catch ""
    else
        "";
    if (footer_text.len != 0) {
        const footer: ui.Rect = .{ .x = area.x + 2, .y = area.y + area.h - 1, .w = area.w -| 4, .h = 1 };
        _ = context.buffer.writeTruncated(footer, footer.x, footer.y, footer_text, footer.w, .{
            .fg = context.palette.subtext0,
            .bg = background,
        });
    }

    return .{
        .area = area,
        .cursor = .{
            .cursor_x = query.x + prefix_width + view.cursor,
            .cursor_y = query.y,
        },
    };
}

test "cell fallback connects every border edge and graphical frame keeps corners untouched" {
    var buffer = try ui.Buffer.init(std.testing.allocator, 40, 12);
    defer buffer.deinit();
    const outside: ui.Style = .{ .bg = .{ .rgb = .{ 1, 2, 3 } } };
    buffer.fill(buffer.area(), "#", outside);
    var hits: widget.Hits = .{};
    var context: widget.Context = .{
        .buffer = &buffer,
        .hits = &hits,
        .palette = &ui.theme.default_theme.palette,
        .hovered = null,
    };
    var field: Field = .{};
    const input: Input = .{
        .title = "goto",
        .field = &field,
        .rows = &.{},
        .total = 0,
        .hint = "scope",
    };

    var cell_frame = input;
    cell_frame.graphical_frame = false;
    const cell_area = render(&context, buffer.area(), cell_frame).area;
    try std.testing.expectEqualStrings("╭", buffer.at(cell_area.x, cell_area.y).?.text());
    try std.testing.expectEqualStrings("╮", buffer.at(cell_area.x + cell_area.w - 1, cell_area.y).?.text());
    try std.testing.expectEqualStrings("╰", buffer.at(cell_area.x, cell_area.y + cell_area.h - 1).?.text());
    try std.testing.expectEqualStrings("╯", buffer.at(cell_area.x + cell_area.w - 1, cell_area.y + cell_area.h - 1).?.text());
    try std.testing.expectEqualStrings("─", buffer.at(cell_area.x + 1, cell_area.y).?.text());
    try std.testing.expectEqualStrings("│", buffer.at(cell_area.x, cell_area.y + 1).?.text());
    try std.testing.expectEqualStrings("─", buffer.at(cell_area.x + 1, cell_area.y + cell_area.h - 1).?.text());
    try std.testing.expectEqualDeep(context.palette.panel_bg, buffer.at(cell_area.x + 1, cell_area.y).?.style.bg);

    buffer.fill(buffer.area(), "#", outside);
    var graphical = input;
    graphical.graphical_frame = true;
    const area = render(&context, buffer.area(), graphical).area;
    try std.testing.expectEqualStrings("#", buffer.at(area.x, area.y).?.text());
    try std.testing.expectEqualStrings("#", buffer.at(area.x + area.w - 1, area.y + area.h - 1).?.text());
    try std.testing.expectEqualStrings(" ", buffer.at(area.x, area.y + 1).?.text());
    try std.testing.expectEqualDeep(context.palette.panel_bg, buffer.at(area.x, area.y + 1).?.style.bg);
}
