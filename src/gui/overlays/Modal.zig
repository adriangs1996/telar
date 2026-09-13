const client = @import("telar-client");
const core = @import("telar-core");
const Canvas = @import("../chrome/Canvas.zig");
const Label = @import("../chrome/Label.zig");
const Modal = @This();

canvas: *Canvas,
area: core.Rect,

/// Centers a bounded modal, retaining a usable field on very small hosts.
/// Example: `const area = Modal.bounds(host, .{ .w = 72, .h = 7 });`.
pub fn bounds(host: core.Rect, wanted: core.Rect) core.Rect {
    const horizontal: u16 = if (host.w > 12) 2 else 0;
    const vertical: u16 = if (host.h > 6) 1 else 0;
    const width = @min(wanted.w, host.w -| horizontal * 2);
    const height = @min(wanted.h, host.h -| vertical * 2);

    return .{ .x = host.x +| (host.w - width) / 2, .y = host.y +| (host.h - height) / 2, .w = width, .h = height };
}

/// Clears the modal before drawing its border and title.
/// Example: `try modal.frame("Rename tab");`.
pub fn frame(modal: Modal, title: []const u8) !void {
    const palette = modal.canvas.theme.palette;
    try modal.canvas.fill(modal.area, palette.panel_bg);
    try modal.canvas.border(modal.area, palette.accent);

    if (modal.area.w > 4) {
        try modal.canvas.text(.{ .x = modal.area.x + 2, .y = modal.area.y, .w = modal.area.w - 4, .h = 1 }, .{ .text = title, .color = palette.accent, .bold = true });
    }
}

/// Paints the shared field's visible selection and cursor without mutating it.
/// Example: `try modal.field(query_area, prompt);`.
pub fn field(modal: Modal, area: core.Rect, prompt: client.Prompt) !void {
    if (area.isEmpty()) {
        return;
    }

    const palette = modal.canvas.theme.palette;
    var editor = prompt.field;
    const view = editor.view(area.w);
    try modal.canvas.fill(area, palette.surface0);

    if (view.selection) |selection| {
        const start = @min(selection[0], area.w);
        const end = @min(selection[1], area.w);
        try modal.canvas.fill(.{ .x = area.x +| start, .y = area.y, .w = end -| start, .h = 1 }, palette.surface1);
    }

    try modal.canvas.text(area, .{ .text = view.text, .color = palette.text });
    try modal.canvas.border(.{ .x = area.x + @min(view.cursor, area.w - 1), .y = area.y, .w = 1, .h = 1 }, palette.accent);
}

/// Draws one clipped line relative to the modal's content rectangle.
/// Example: `try modal.line(1, .{ .text = "Enter to confirm", .color = color });`.
pub fn line(modal: Modal, row: u16, label: Label) !void {
    try modal.canvas.text(modal.content().row(row), label);
}

/// Example: `const inner = modal.content();`.
pub fn content(modal: Modal) core.Rect {
    return if (modal.area.w > 2 and modal.area.h > 2) modal.area.inner(1) else modal.area;
}
