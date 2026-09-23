const data = @import("model");
const Canvas = @import("Canvas.zig");
const Rect = @import("../render/Rect.zig");
const FormButton = @import("FormButton.zig");
const ChangeReviewButton = @This();

area: Rect,
pane: *const data.Pane,
placement: enum { pane_header, fullscreen, top_bar } = .pane_header,

/// Reserves visible header space before registering its delivered action.
/// Example: `header.width -= try button.draw(canvas);`
pub fn draw(self: ChangeReviewButton, canvas: *Canvas) !f32 {
    if (!self.pane.hasChangeReview()) {
        return 0;
    }

    const gap = canvas.chrome.px(8);
    const inset = canvas.chrome.px(16);
    const full_width = try canvas.measure(.{ .text = "Review changes", .face = .sans, .size = .body }) + inset;
    const compact_width = try canvas.measure(.{ .text = "Review", .face = .sans, .size = .body }) + inset;
    const available = self.area.width / 2;
    const top_bar = self.placement == .top_bar;
    const minimum_width = if (top_bar) canvas.chrome.px(28) else compact_width;
    if (self.area.height <= 0 or available < minimum_width + gap) {
        return 0;
    }

    const width = if (top_bar) minimum_width else if (available >= full_width + gap) full_width else compact_width;
    const height = @min(self.area.height, canvas.chrome.px(28));
    try (FormButton{
        .bounds = .{ .x = self.area.x + self.area.width - width, .y = self.area.y + (self.area.height - height) / 2, .width = width, .height = height },
        .text = if (top_bar) "±" else if (width == full_width) "Review changes" else "Review",
        .label = "Review changes",
        .action = .{ .change_review = self.pane.id },
        .generation = self.pane.attachment_generation,
        .namespace = @intFromEnum(self.placement),
        .layer = 0,
        .quiet = true,
    }).draw(canvas);
    return width + gap;
}
