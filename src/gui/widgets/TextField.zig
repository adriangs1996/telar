//! A bounded editable surface drawn in Zig. Its owner supplies committed text
//! and selection; provisional IME text belongs to the interaction state.
const client = @import("telar-client");
const Canvas = @import("Canvas.zig");
const Target = @import("interaction/Target.zig");
const Rect = @import("../render/Rect.zig");
const TextField = @This();
const GenericField = client.GenericField;
const EditorDisplay = @import("interaction/EditorDisplay.zig");

bounds: Rect,
text: []const u8,
selection: [2]u32,
action: Target.Action,
generation: u64,
focused: bool = true,
label: []const u8 = "Text",
/// Form controls use chrome-sized text, padding and a thin insertion caret.
form_control: bool = false,
placeholder: []const u8 = "",
layer: u8 = 1,
multiline: bool = false,
appearance: enum { standard, embedded } = .standard,
face: @import("label_face.zig").Face = .mono,
font_pixels: ?u16 = null,

/// Borrows one canonical prompt field only for synchronous drawing.
/// Example: `try TextField.fromPrompt(&prompt, bounds, .name).draw(canvas);`
pub fn fromPrompt(prompt: *const client.Prompt, bounds: Rect, field: Target.Field) TextField {
    const directory = field == .directory;
    return .{
        .bounds = bounds,
        .text = if (directory) prompt.directory.text() else prompt.field.text(),
        .selection = if (directory) .{ @intCast(prompt.directory.anchor), @intCast(prompt.directory.head) } else .{ @intCast(prompt.field.anchor), @intCast(prompt.field.head) },
        .action = .{ .text_field = field },
        .generation = prompt.generation,
        .focused = if (prompt.form()) |form| (form.focus == .directory) == directory else !directory,
        .label = if (directory) "Working directory" else "Name or query",
    };
}

/// Paints committed/provisional text and registers the same pixel rectangle
/// for selection, focus and native text-context queries.
/// Example: `try field.draw(canvas);`
pub fn draw(widget: TextField, canvas: *Canvas) !void {
    if (widget.bounds.width <= 0 or widget.bounds.height <= 0) {
        return;
    }

    var painter = canvas.*;
    var content = widget.bounds;
    const palette = canvas.theme.palette;
    const first_quad = canvas.quads.items().len;
    defer canvas.quads.clipFrom(first_quad, widget.bounds);
    var font: ?@import("interaction/EditorFont.zig") = null;
    if (widget.multiline and widget.face == .sans) {
        const height = widget.font_pixels orelse @max(1, canvas.chrome.body);
        const box = try canvas.atlas.lineBox(.sans, height);
        _ = try canvas.atlas.cellWidth(height);
        painter.chrome.body = height;
        painter.metrics = .{ .cell_width = 1, .cell_height = @intFromFloat(@min(65535, @ceil(box.height + canvas.chrome.px(3)))), .baseline = box.ascender, .pixel_height = height };
        font = .{ .atlas = canvas.atlas, .pixel_height = height };
    }

    if (widget.appearance == .embedded) {
        // The surrounding composer owns padding, focus and its single border.
    } else if (widget.form_control) {
        const height = @max(1, canvas.chrome.body);
        painter.metrics = .{ .cell_width = try canvas.atlas.cellWidth(height), .cell_height = @intCast(@min(65535, try canvas.atlas.lineHeight(height))), .baseline = @floatFromInt(try canvas.atlas.ascender(height)), .pixel_height = height };
        const inset = @min(canvas.chrome.px(12), content.width / 4);
        content.x += inset;
        content.width = @max(0, content.width - 2 * inset);
        content.height = if (widget.multiline) content.height - @min(canvas.chrome.px(20), content.height / 3) else @min(@as(f32, @floatFromInt(painter.metrics.cell_height)), content.height - @min(canvas.chrome.px(8), content.height / 3));
        content.y += @floor((widget.bounds.height - content.height) / 2);
        try canvas.fillRoundedAt(widget.bounds, .{ .color = palette.surface0, .radius = canvas.chrome.px(7) });
        try canvas.ringAt(widget.bounds, .{ .color = if (widget.focused) palette.accent else palette.overlay0, .radius = canvas.chrome.px(7), .width = canvas.chrome.px(if (widget.focused) 1.5 else 1), .alpha = if (widget.focused) 0.9 else 0.45 });
    } else {
        try canvas.fillAt(widget.bounds, if (widget.focused) palette.surface0 else palette.surface_dim);
    }

    if (content.width <= 0 or content.height <= 0) {
        return;
    }

    const cell: f32 = @floatFromInt(painter.metrics.cell_width);
    const columns: u16 = @intFromFloat(@min(65535, @max(1, @floor(content.width / cell))));
    var preedit: ?*const @import("interaction/Preedit.zig") = null;
    if (canvas.widgets) |state| {
        const target = (Target{ .id = .{ .generation = widget.generation }, .bounds = widget.bounds, .action = widget.action, .layer = widget.layer, .traverse_tab = widget.action == .composer, .role = 3 }).labelled(widget.label);
        const id = try state.dispatcher.add(target);
        try state.editors.preparing().add(.{ .id = id, .bounds = content, .columns = columns, .cell_width = cell, .preferred = widget.focused, .multiline = widget.multiline, .line_height = @floatFromInt(painter.metrics.cell_height), .font = font });
        if (state.preedit.owner) |owner| {
            if (owner.eql(id)) {
                preedit = &state.preedit;
            }
        }
    }

    var display = EditorDisplay.capture(.{ .text = widget.text, .anchor = widget.selection[0], .head = widget.selection[1] }, preedit);
    if (font) |proportional| {
        try proportional.prepare(display.field.text());
    }

    if (widget.multiline) {
        try widget.drawMultiline(&painter, .{ .display = &display, .content = content, .columns = columns, .font = font });
        return;
    }

    const view = display.field.view(columns);
    if (view.selection) |selected| {
        const start = @min(selected[0], columns);
        const end = @min(selected[1], columns);
        try canvas.fillAt(.{ .x = content.x + @as(f32, @floatFromInt(start)) * cell, .y = content.y, .width = @as(f32, @floatFromInt(end -| start)) * cell, .height = content.height }, palette.surface1);
    }

    if (view.text.len == 0 and widget.placeholder.len > 0) {
        _ = try canvas.textAt(content, .{ .text = widget.placeholder, .color = palette.subtext0, .alpha = 0.7, .face = .sans, .size = .body });
    } else {
        _ = try painter.textAt(content, .{ .text = view.text, .color = palette.text, .underline = display.provisional });
    }

    if (widget.focused) {
        const caret: Rect = .{ .x = content.x + @as(f32, @floatFromInt(@min(view.cursor, columns - 1))) * cell, .y = content.y, .width = @min(if (widget.form_control) @max(1, canvas.chrome.px(1)) else cell, content.width), .height = content.height };
        if (widget.form_control) {
            try canvas.fillAt(caret, palette.text);
        } else {
            try canvas.ringAt(caret, .{ .width = 1, .color = palette.accent });
        }
    }
}

fn drawMultiline(widget: TextField, canvas: *Canvas, input: @import("MultilinePaint.zig")) !void {
    const content = input.content;
    const display = input.display;
    const field = &display.field;
    const palette = canvas.theme.palette;
    const line_height: f32 = @floatFromInt(canvas.metrics.cell_height);
    const cell_width: f32 = @floatFromInt(canvas.metrics.cell_width);
    const rows: u32 = @intFromFloat(@max(1, @floor(content.height / line_height)));
    const layout: @import("interaction/MultilineLayout.zig") = .{ .text = field.text(), .head = @intCast(field.head), .columns = input.columns, .rows = rows, .font = input.font };
    const first = layout.firstRow();
    const selection = [2]usize{ @min(field.head, field.anchor), @max(field.head, field.anchor) };
    var lines: @import("interaction/EditorLines.zig") = .{ .text = field.text(), .width = input.columns, .font = input.font };
    var row: u32 = 0;
    while (lines.next()) |line| : (row += 1) {
        if (row < first) {
            continue;
        }
        if (row - first >= rows) {
            break;
        }

        const area: Rect = .{ .x = content.x, .y = content.y + @as(f32, @floatFromInt(row - first)) * line_height, .width = content.width, .height = @min(line_height, content.height) };
        const start = @intFromPtr(line.ptr) - @intFromPtr(field.text().ptr);
        const from = @min(line.len, selection[0] -| start);
        const to = @min(line.len, selection[1] -| start);
        if (from < to) {
            const from_x = lines.position(from);
            const to_x = lines.position(to);
            const x: f32 = @floatFromInt(@min(from_x, to_x));
            const width: f32 = @floatFromInt(@max(from_x, to_x) - @min(from_x, to_x));
            try canvas.fillAt(.{ .x = area.x + x * cell_width, .y = area.y, .width = @min(width * cell_width, area.width - x * cell_width), .height = area.height }, palette.surface1);
        }

        if (input.font != null) {
            _ = try canvas.textAt(area, .{ .text = if (field.len == 0) widget.placeholder else line, .face = .sans, .size = .body, .color = if (field.len == 0) palette.subtext0 else palette.text, .alpha = if (field.len == 0) 0.72 else 1, .underline = display.provisional });
        } else {
            _ = try canvas.textAt(area, .{ .text = if (field.len == 0) widget.placeholder else line, .color = if (field.len == 0) palette.subtext0 else palette.text, .underline = display.provisional });
        }
    }

    if (widget.focused) {
        const caret = layout.position(@intCast(field.head));
        try canvas.fillAt(.{ .x = content.x + @as(f32, @floatFromInt(@min(caret[0], input.columns -| 1))) * cell_width, .y = content.y + @as(f32, @floatFromInt(caret[1] -| first)) * line_height, .width = @max(1, canvas.chrome.px(1)), .height = @min(line_height, content.height) }, palette.text);
    }
}
