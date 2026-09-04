//! Inline tab-name editor occupying the bottom bar.

const core = @import("telar-core");
const edit = @import("../input/root.zig").edit;
const widget = @import("context.zig");
const ui = @import("../ui/root.zig");

const schema = core.schema;

pub const Field = edit.Field(schema.max_tab_label_bytes);
pub const Kind = enum { rename_tab, create_workspace, rename_workspace, copy_search_forward, copy_search_backward };

pub const Output = widget.Cursor;

pub const Input = struct {
    area: ui.Rect,
    field: *Field,
    kind: Kind,
};

/// Renders one tab or workspace name prompt and returns its cursor.
/// For example: `const cursor = render(context, .{ .area = area, .field = field, .kind = .rename_tab });`.
pub fn render(context: *widget.Context, input: Input) Output {
    const area = input.area;
    const field = input.field;
    const prefix = switch (input.kind) {
        .rename_tab => " rename tab: ",
        .create_workspace => " new workspace: ",
        .rename_workspace => " rename workspace: ",
        .copy_search_forward => " /",
        .copy_search_backward => " ?",
    };
    _ = context.buffer.writeText(area, .{ .point = .{ .x = area.x, .y = area.y }, .text = prefix, .style = .{
        .fg = context.palette.accent,
        .bg = context.palette.panel_bg,
        .flags = .{ .bold = true },
    } });
    const field_x = area.x + ui.measure(prefix);
    const field_area: ui.Rect = .{
        .x = field_x,
        .y = area.y,
        .w = area.w -| (field_x - area.x),
        .h = 1,
    };
    const view = field.view(field_area.w);
    _ = context.buffer.writeTruncated(field_area, .{ .point = .{ .x = field_x, .y = area.y }, .text = view.text, .max_width = field_area.w, .style = .{
        .fg = context.palette.text,
        .bg = context.palette.surface0,
        .flags = .{ .bold = true },
    } });
    return .{
        .cursor_x = field_x + view.cursor,
        .cursor_y = area.y,
    };
}
