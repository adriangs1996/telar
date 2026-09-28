//! The clipboard images pasted into the focused agent's prompt, as cards in
//! the rows reserved below its pane. A card opens its image in the preview
//! modal; its `×` deletes the image's marker from the prompt, then retires
//! the preview.
const cellgrid = @import("cellgrid");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const Canvas = @import("Canvas.zig");
const Label = @import("Label.zig");
const Target = @import("interaction/Target.zig");
const ImagePreviews = @import("../ImagePreviews.zig");
const ImagePreviewShelf = @This();

/// Logical pixels of the shelf's padding, the gap between cards, the widest
/// card and the close control.
const padding: f32 = 6;
const gap: f32 = 6;
const max_card_width: f32 = 180;
const close_side: f32 = 18;
const card_radius: f32 = 8;
/// Target namespaces: a card and its close control act on the same preview.
const card_namespace: u64 = 1;
const close_namespace: u64 = 2;

area: cellgrid.Rect,
previews: *const ImagePreviews,

/// Example: `try shelf.draw(canvas);`
pub fn draw(self: ImagePreviewShelf, canvas: *Canvas) !void {
    const snapshot = self.previews.catalog.snapshot();
    if (snapshot.len == 0 or self.area.isEmpty()) {
        return;
    }

    const palette = canvas.theme.palette;
    const px = canvas.chrome;
    const bounds = canvas.rect(self.area);
    try canvas.fillAt(bounds, canvas.covering(palette.panel_bg));

    const inner: Rect = .{
        .x = bounds.x + px.px(padding),
        .y = bounds.y + px.px(padding),
        .width = bounds.width - 2 * px.px(padding),
        .height = bounds.height - 2 * px.px(padding),
    };
    const count: f32 = @floatFromInt(snapshot.len);
    const width = @min(px.px(max_card_width), (inner.width - (count - 1) * px.px(gap)) / count);
    if (width <= 0 or inner.height <= 0) {
        return;
    }

    for (snapshot.slice(), 0..) |item, index| {
        const card: Rect = .{
            .x = inner.x + @as(f32, @floatFromInt(index)) * (width + px.px(gap)),
            .y = inner.y,
            .width = width,
            .height = inner.height,
        };
        const card_hovered = try register(canvas, (Target{ .bounds = card, .action = .{ .preview = .{ .open = item.id } }, .namespace = card_namespace, .focusable = false }).labelled("Open image preview"));
        try canvas.fillRoundedAt(card, .{ .color = if (card_hovered) palette.surface1 else palette.surface0, .radius = px.px(card_radius) });

        if (self.previews.thumbnailUv(item.id)) |uv| {
            const image_area: Rect = .{
                .x = card.x + px.px(padding),
                .y = card.y + px.px(padding),
                .width = card.width - 2 * px.px(padding),
                .height = card.height - 2 * px.px(padding),
            };
            try canvas.diagramRegionAt(fitted(image_area, item.width, item.height), ImagePreviews.sheet_slot, uv);
        }

        const close: Rect = .{
            .x = card.x + card.width - px.px(close_side + padding),
            .y = card.y + px.px(padding),
            .width = px.px(close_side),
            .height = px.px(close_side),
        };
        const hovered = try register(canvas, (Target{ .bounds = close, .action = .{ .intent = .{ .attachment_dismiss = item.id } }, .namespace = close_namespace, .focusable = false }).labelled("Remove image"));
        try canvas.fillRoundedAt(close, .{ .color = palette.surface1, .radius = px.px(close_side / 2) });
        const mark: Label = .{ .text = "\u{00d7}", .color = if (hovered) palette.red else palette.subtext0, .face = .sans, .size = .body, .bold = true };
        const mark_width = try canvas.measure(mark);
        _ = try canvas.textAt(.{ .x = close.x + (close.width - mark_width) / 2, .y = close.y, .width = mark_width, .height = close.height }, mark);
    }
}

/// The largest rectangle with the image's aspect centered in `area`.
/// Example: `const image = fitted(card, item.width, item.height);`
pub fn fitted(area: Rect, width: u32, height: u32) Rect {
    if (area.width <= 0 or area.height <= 0 or width == 0 or height == 0) {
        return .{ .x = area.x, .y = area.y, .width = 0, .height = 0 };
    }

    const image_width: f32 = @floatFromInt(width);
    const image_height: f32 = @floatFromInt(height);
    const scale = @min(area.width / image_width, area.height / image_height);
    const fitted_width = image_width * scale;
    const fitted_height = image_height * scale;
    return .{
        .x = area.x + (area.width - fitted_width) / 2,
        .y = area.y + (area.height - fitted_height) / 2,
        .width = fitted_width,
        .height = fitted_height,
    };
}

/// Registers a pointer target and reports whether the pointer rests on it.
fn register(canvas: *Canvas, target: Target) !bool {
    const state = canvas.widgets orelse return false;
    const id = try state.dispatcher.add(target);
    return if (state.dispatcher.hovered) |hover| hover.eql(id) else false;
}
