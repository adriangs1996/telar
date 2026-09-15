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
    if (widget.form_control) {
        const height = @max(1, canvas.chrome.body);
        painter.metrics = .{ .cell_width = try canvas.atlas.cellWidth(height), .cell_height = @intCast(@min(65535, try canvas.atlas.lineHeight(height))), .baseline = @floatFromInt(try canvas.atlas.ascender(height)), .pixel_height = height };
        const inset = @min(canvas.chrome.px(12), content.width / 4);
        content.x += inset;
        content.width = @max(0, content.width - 2 * inset);
        content.height = @min(@as(f32, @floatFromInt(painter.metrics.cell_height)), content.height - @min(canvas.chrome.px(8), content.height / 3));
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
        const target = (Target{ .id = .{ .generation = widget.generation }, .bounds = widget.bounds, .action = widget.action, .layer = 1, .traverse_tab = false, .role = 3 }).labelled(widget.label);
        const id = try state.dispatcher.add(target);
        try state.editors.preparing().add(.{ .id = id, .bounds = content, .columns = columns, .cell_width = cell, .preferred = widget.focused });
        if (state.preedit.owner) |owner| {
            if (owner.eql(id)) {
                preedit = &state.preedit;
            }
        }
    }

    var display = EditorDisplay.capture(.{ .text = widget.text, .anchor = widget.selection[0], .head = widget.selection[1] }, preedit);
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
