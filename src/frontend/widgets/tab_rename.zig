//! Inline tab-name editor occupying the bottom bar.

const GenericField = @import("telar-client").GenericField;
const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const ContextType = @import("Context.zig");
const TabRenameInput = @import("TabRenameInput.zig");
const CursorType = @import("Cursor.zig");
const measure_module = @import("telar-core").measure;
const RectType = @import("telar-core").Rect;
const WorkspaceFormType = @import("telar-client").WorkspaceForm;
const StyleType = @import("telar-core").Style;
const LabelInput = @import("InlineLabel.zig");
const FieldInput = @import("InlineField.zig");

pub const Field = GenericField(max_tab_label_bytes_module);
pub const Kind = enum { rename_tab, create_workspace, rename_workspace, copy_search_forward, copy_search_backward };

pub const create_hint = " create? ↵";

/// Renders one tab or workspace name prompt and returns its cursor. The
/// new-context form shows both fields and its completions on the same row.
/// For example: `const cursor = render(context, .{ .area = area, .field = field, .kind = .rename_tab });`.
pub fn render(context: *ContextType, input: TabRenameInput) CursorType {
    if (input.kind == .create_workspace) {
        if (input.prompt) |prompt| {
            if (prompt.form()) |form| {
                return renderCreateForm(context, input, form);
            }
        }
    }

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
    const field_x = area.x + measure_module(prefix);
    const field_area: RectType = .{
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

/// `new context: name  dir: directory  completions…` in one row; the
/// completion names follow the directory field and the selected one is
/// highlighted. A pending confirmation replaces the list.
fn renderCreateForm(context: *ContextType, input: TabRenameInput, form: *const WorkspaceFormType) CursorType {
    const area = input.area;
    const prompt = input.prompt.?;
    const label_style: StyleType = .{ .fg = context.palette.accent, .bg = context.palette.panel_bg, .flags = .{ .bold = true } };
    var x = area.x;
    const end = area.x + area.w;
    x += writeLabel(context, .{ .area = area, .x = x, .text = " new context: ", .style = label_style });

    const name_area: RectType = .{ .x = x, .y = area.y, .w = @min(24, end -| x), .h = 1 };
    var name_field = prompt.field;
    const name_view = name_field.view(name_area.w);
    writeField(context, .{ .area = name_area, .text = name_view.text, .focused = form.focus == .name });
    x = name_area.x + name_area.w;
    x += writeLabel(context, .{ .area = area, .x = x, .text = " dir: ", .style = label_style });

    const remaining = end -| x;
    const entries = if (input.path_completion) |state| state.entries() else &.{};
    const list_wanted = !form.confirm_create and entries.len != 0 and remaining > 30;
    const hint_width: u16 = if (form.confirm_create) @min(measure_module(create_hint), remaining / 2) else 0;
    const directory_area: RectType = .{ .x = x, .y = area.y, .w = if (list_wanted) remaining / 2 else remaining - hint_width, .h = 1 };
    var directory_field = prompt.directory;
    const directory_view = directory_field.view(directory_area.w);
    writeField(context, .{ .area = directory_area, .text = directory_view.text, .focused = form.focus == .directory });
    x = directory_area.x + directory_area.w;

    if (form.confirm_create) {
        _ = writeLabel(context, .{ .area = area, .x = x, .text = create_hint, .style = .{ .fg = context.palette.yellow, .bg = context.palette.panel_bg, .flags = .{ .bold = true } } });
    } else if (list_wanted) {
        const selected: usize = @min(prompt.selection(), entries.len - 1);
        for (entries[selected..], selected..) |entry, index| {
            if (x >= end) {
                break;
            }

            x += writeLabel(context, .{ .area = area, .x = x, .text = " ", .style = label_style });
            const highlighted = form.focus == .directory and index == selected;
            x += writeLabel(context, .{ .area = area, .x = x, .text = entry.slice(), .style = .{
                .fg = if (highlighted) context.palette.accent else context.palette.subtext0,
                .bg = if (highlighted) context.palette.surface1 else context.palette.panel_bg,
                .flags = .{ .bold = highlighted },
            } });
        }
    }

    return if (form.focus == .name)
        .{ .cursor_x = name_area.x + @min(name_view.cursor, name_area.w -| 1), .cursor_y = area.y }
    else
        .{ .cursor_x = directory_area.x + @min(directory_view.cursor, directory_area.w -| 1), .cursor_y = area.y };
}

fn writeLabel(context: *ContextType, input: LabelInput) u16 {
    const area = input.area;
    const x = input.x;
    const text = input.text;
    const style = input.style;
    const width = @min(measure_module(text), (area.x + area.w) -| x);
    if (width == 0) {
        return 0;
    }

    _ = context.buffer.writeTruncated(area, .{ .point = .{ .x = x, .y = area.y }, .text = text, .max_width = width, .style = style });
    return width;
}

fn writeField(context: *ContextType, input: FieldInput) void {
    const area = input.area;
    const text = input.text;
    const focused = input.focused;
    if (area.w == 0) {
        return;
    }

    context.buffer.fill(area, .{ .glyph = " ", .style = .{ .bg = if (focused) context.palette.surface0 else context.palette.surface_dim } });
    _ = context.buffer.writeTruncated(area, .{ .point = .{ .x = area.x, .y = area.y }, .text = text, .max_width = area.w, .style = .{
        .fg = context.palette.text,
        .bg = if (focused) context.palette.surface0 else context.palette.surface_dim,
        .flags = .{ .bold = focused },
    } });
}
