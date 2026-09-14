const core = @import("telar-core");
const Canvas = @import("../Canvas.zig");
const Modal = @This();

area: core.Rect,
title: []const u8,

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
/// Example: `try (Modal{ .area = area, .title = "Rename tab" }).draw(canvas);`
pub fn draw(modal: Modal, canvas: *Canvas) !void {
    const palette = canvas.theme.palette;
    try canvas.fill(modal.area, canvas.covering(palette.panel_bg));
    try canvas.border(modal.area, palette.accent);

    if (modal.area.w > 4) {
        try canvas.text(.{ .x = modal.area.x + 2, .y = modal.area.y, .w = modal.area.w - 4, .h = 1 }, .{ .text = modal.title, .color = palette.accent, .bold = true });
    }
}

/// Example: `const inner = modal.content();`.
pub fn content(modal: Modal) core.Rect {
    return if (modal.area.w > 2 and modal.area.h > 2) modal.area.inner(1) else modal.area;
}
