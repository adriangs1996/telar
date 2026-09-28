//! One clipboard image from the preview shelf, as large as the window
//! allows. A press outside the modal, its `×` or Esc closes it; the client
//! routes Esc through the shelf's modal ownership.
const cellgrid = @import("cellgrid");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const Canvas = @import("../Canvas.zig");
const Label = @import("../Label.zig");
const Target = @import("../interaction/Target.zig");
const Modal = @import("Modal.zig");
const ImagePreviewShelf = @import("../ImagePreviewShelf.zig");
const ImagePreviews = @import("../../ImagePreviews.zig");
const ImagePreviewModal = @This();

/// Cells the modal leaves around itself on each axis, and the rows its
/// title and hint take inside the border.
const margin_columns: u16 = 8;
const margin_rows: u16 = 4;
/// The scrim over the window behind the modal.
const scrim_alpha: f32 = 0.55;

/// The whole window, in cells.
area: cellgrid.Rect,
previews: *const ImagePreviews,

/// Example: `try modal.draw(canvas);`
pub fn draw(self: ImagePreviewModal, canvas: *Canvas) !void {
    const id = self.previews.catalog.modal orelse return;
    const snapshot = self.previews.catalog.snapshot();
    const item = for (snapshot.slice()) |value| {
        if (value.id == id) {
            break value;
        }
    } else return;

    const palette = canvas.theme.palette;
    const window = canvas.rect(self.area);
    try register(canvas, (Target{ .bounds = window, .action = .{ .preview = .close }, .focusable = false }).labelled("Close image preview"));
    try canvas.dimAt(window, scrim_alpha);

    const modal: Modal = .{
        .area = Modal.bounds(self.area, .{ .w = self.area.w -| margin_columns, .h = self.area.h -| margin_rows }),
        .title = "Image preview",
    };
    try modal.draw(canvas);
    try register(canvas, (Target{ .bounds = canvas.rect(modal.area), .action = .{ .preview = .hold }, .focusable = false }).labelled("Image preview"));

    if (modal.area.w > 4) {
        const close = canvas.rect(.{ .x = modal.area.x + modal.area.w - 3, .y = modal.area.y, .w = 2, .h = 1 });
        try register(canvas, (Target{ .bounds = close, .action = .{ .preview = .close }, .namespace = 1, .focusable = false }).labelled("Close image preview"));
        try canvas.text(.{ .x = modal.area.x + modal.area.w - 3, .y = modal.area.y, .w = 2, .h = 1 }, .{ .text = "\u{00d7}", .color = palette.subtext0 });
    }

    const content = modal.content();
    if (content.h < 3) {
        return;
    }

    const image = canvas.rect(.{ .x = content.x, .y = content.y, .w = content.w, .h = content.h - 1 });
    if (self.previews.modalReady()) {
        try canvas.diagramAt(ImagePreviewShelf.fitted(image, item.width, item.height), ImagePreviews.modal_slot);
    } else {
        try canvas.text(content.row(content.h / 2), .{ .text = "The image could not be decoded", .color = palette.subtext0 });
    }

    try canvas.text(content.row(content.h - 1), .{ .text = "Esc close", .color = palette.subtext0 });
}

fn register(canvas: *Canvas, target: Target) !void {
    const state = canvas.widgets orelse return;
    _ = try state.dispatcher.add(target);
}
