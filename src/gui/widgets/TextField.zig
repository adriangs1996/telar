//! A bounded editable surface drawn in Zig. Its owner supplies committed text
//! and selection; provisional IME text belongs to the interaction state.
const std = @import("std");
const client = @import("telar-client");
const Canvas = @import("../chrome/Canvas.zig");
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

    const columns: u16 = @intFromFloat(@min(65535, @max(1, @floor(widget.bounds.width / @as(f32, @floatFromInt(canvas.metrics.cell_width))))));
    var preedit: ?*const @import("interaction/Preedit.zig") = null;
    if (canvas.widgets) |state| {
        const target = (Target{ .id = .{ .generation = widget.generation }, .bounds = widget.bounds, .action = widget.action, .layer = 1, .traverse_tab = false, .role = 3 }).labelled(widget.label);
        const id = try state.dispatcher.add(target);
        try state.editors.preparing().add(.{ .id = id, .bounds = widget.bounds, .columns = columns, .cell_width = @floatFromInt(canvas.metrics.cell_width), .preferred = widget.focused });
        if (state.preedit.owner) |owner| {
            if (owner.eql(id)) {
                preedit = &state.preedit;
            }
        }
    }

    var display = EditorDisplay.capture(.{ .text = widget.text, .anchor = widget.selection[0], .head = widget.selection[1] }, preedit);
    const view = display.field.view(columns);
    const palette = canvas.theme.palette;
    try canvas.fillAt(widget.bounds, if (widget.focused) palette.surface0 else palette.surface_dim);
    if (view.selection) |selected| {
        const start = @min(selected[0], columns);
        const end = @min(selected[1], columns);
        const cell: f32 = @floatFromInt(canvas.metrics.cell_width);
        try canvas.fillAt(.{ .x = widget.bounds.x + @as(f32, @floatFromInt(start)) * cell, .y = widget.bounds.y, .width = @as(f32, @floatFromInt(end -| start)) * cell, .height = widget.bounds.height }, palette.surface1);
    }

    _ = try canvas.textAt(widget.bounds, .{ .text = view.text, .color = palette.text, .underline = display.provisional });
    if (widget.focused) {
        const cell: f32 = @floatFromInt(canvas.metrics.cell_width);
        try canvas.ringAt(.{ .x = widget.bounds.x + @as(f32, @floatFromInt(@min(view.cursor, columns - 1))) * cell, .y = widget.bounds.y, .width = @min(cell, widget.bounds.width), .height = widget.bounds.height }, .{ .width = 1, .color = palette.accent });
    }
}
