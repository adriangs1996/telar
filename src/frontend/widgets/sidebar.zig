//! Pane navigation sidebar.

const std = @import("std");
const core = @import("telar-core");
const multiplexer = @import("../multiplexer.zig");
const widget = @import("context.zig");
const ui = @import("../ui.zig");

const schema = core.schema;

pub const Semantic = struct {
    area: ui.Rect,
    rows: [multiplexer.max_panes]Row = undefined,
    row_count: usize = 0,
    focused_row: ?u16 = null,

    pub const Row = struct {
        area: ui.Rect,
        pane_id: schema.PaneId,
        focused: bool,
        hovered: bool,
    };
};

pub const Input = struct {
    area: ui.Rect,
    model: *const multiplexer.Model,
    transparent: bool,
};

pub fn render(context: *widget.Context, input: Input) Semantic {
    var semantic = describe(context, input.area, input.model);
    renderCells(context, &semantic, input.transparent);
    return semantic;
}

fn describe(
    context: *widget.Context,
    area: ui.Rect,
    model: *const multiplexer.Model,
) Semantic {
    var semantic: Semantic = .{ .area = area };
    if (area.isEmpty() or area.h <= 2) return semantic;

    var row: u16 = area.y + 3;
    for (&model.panes) |*slot| {
        const pane = if (slot.*) |*value| value else continue;
        if (row >= area.y + area.h) break;
        const row_area: ui.Rect = .{
            .x = area.x,
            .y = row,
            .w = area.w -| 1,
            .h = 1,
        };
        const action: widget.Action = .{ .focus_pane = pane.id };
        context.hits.add(row_area, action);
        const focused = model.layout.focused() == pane.id;
        semantic.rows[semantic.row_count] = .{
            .area = row_area,
            .pane_id = pane.id,
            .focused = focused,
            .hovered = context.isHovered(action),
        };
        semantic.row_count += 1;
        if (focused) semantic.focused_row = row;
        row += 1;
    }
    return semantic;
}

fn renderCells(context: *widget.Context, semantic: *const Semantic, transparent: bool) void {
    const area = semantic.area;
    if (area.isEmpty()) return;
    const background: ui.Color = if (transparent) .default else context.palette.panel_bg;
    const faint: ui.Style = .{ .fg = context.palette.overlay0, .bg = background };
    const heading: ui.Style = .{
        .fg = context.palette.accent,
        .bg = background,
        .flags = .{ .bold = true },
    };
    context.buffer.fill(area, " ", .{ .fg = context.palette.text, .bg = background });
    _ = context.buffer.writeText(area, area.x + 1, area.y, "TELAR", heading);
    if (!transparent and area.w > 1) {
        const edge_x = area.x + area.w - 1;
        var y = area.y;
        while (y < area.y + area.h) : (y += 1)
            context.buffer.setCell(edge_x, y, "│", 1, faint);
    }
    if (area.h <= 2) return;
    _ = context.buffer.writeText(area, area.x + 1, area.y + 2, "PANES", faint);
    for (semantic.rows[0..semantic.row_count]) |row| {
        const style: ui.Style = if (row.focused)
            .{
                .fg = context.palette.text,
                .bg = if (transparent) .default else context.palette.surface0,
                .flags = .{ .bold = true },
            }
        else if (row.hovered)
            .{
                .fg = context.palette.text,
                .bg = if (transparent) .default else context.palette.surface1,
                .flags = .{ .underline = .single },
            }
        else
            .{ .fg = context.palette.subtext0, .bg = background };
        context.buffer.fill(row.area, " ", style);
        var label_buffer: [48]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buffer, "  pane {d}", .{schema.id.raw(row.pane_id)}) catch "  pane";
        _ = context.buffer.writeTruncated(row.area, row.area.x, row.area.y, label, row.area.w, style);
    }
}
