//! Inline tab-name editor occupying the bottom bar.

const core = @import("telar-core");
const edit = @import("../input/root.zig").edit;
const widget = @import("context.zig");
const ui = @import("../ui/root.zig");

const schema = core.schema;

pub const Field = edit.Field(schema.max_tab_label_bytes);
pub const Kind = enum { rename_tab, create_workspace, rename_workspace, copy_search_forward, copy_search_backward };

pub const Output = widget.Cursor;

pub fn render(context: *widget.Context, area: ui.Rect, field: *Field, kind: Kind) Output {
    const prefix = switch (kind) {
        .rename_tab => " rename tab: ",
        .create_workspace => " new workspace: ",
        .rename_workspace => " rename workspace: ",
        .copy_search_forward => " /",
        .copy_search_backward => " ?",
    };
    _ = context.buffer.writeText(area, area.x, area.y, prefix, .{
        .fg = context.palette.accent,
        .bg = context.palette.panel_bg,
        .flags = .{ .bold = true },
    });
    const field_x = area.x + ui.measure(prefix);
    const field_area: ui.Rect = .{
        .x = field_x,
        .y = area.y,
        .w = area.w -| (field_x - area.x),
        .h = 1,
    };
    const view = field.view(field_area.w);
    _ = context.buffer.writeTruncated(
        field_area,
        field_x,
        area.y,
        view.text,
        field_area.w,
        .{
            .fg = context.palette.text,
            .bg = context.palette.surface0,
            .flags = .{ .bold = true },
        },
    );
    return .{
        .cursor_x = field_x + view.cursor,
        .cursor_y = area.y,
    };
}
