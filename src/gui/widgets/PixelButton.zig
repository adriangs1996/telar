//! A chrome control in device pixels with one semantic intent.
const core = @import("telar-core");
const client = @import("telar-client");
const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
const Label = @import("Label.zig");
const AttentionDot = @import("AttentionDot.zig");
const Layout = @import("../layout/Layout.zig");
const Item = @import("../layout/Item.zig");
const Action = @import("action.zig").Action;
const PixelButton = @This();

context: *const Context,
area: @import("../render/Rect.zig"),
intent: client.Intent,
text: []const u8,
active: bool = false,
background: bool = true,
alignment: @import("../layout/alignment.zig").Alignment = .start,
radius: f32 = 999,
bold: bool = false,
face: @import("label_face.zig").Face = .sans,
size: @import("label_size.zig").Size = .body,
/// Horizontal inset of the label inside the control, in device pixels.
inset: f32 = 0,
/// An attention dot painted at the trailing edge in this color, if any.
dot: ?core.Color = null,

/// Paints and registers a pixel control. Plain controls retain a clear
/// background on hover; centered labels reserve equal space around their dot.
/// Example: `try button.draw(canvas);`
pub fn draw(button: PixelButton, canvas: *Canvas) !void {
    if (button.area.width <= 0 or button.area.height <= 0) {
        return;
    }

    const palette = canvas.theme.palette;
    const action: Action = .{ .intent = button.intent };
    const hovered = button.context.isHovered(action);
    if (button.background) {
        const fill: core.Color = if (button.active) palette.accent else if (hovered) palette.surface1 else palette.surface0;
        try canvas.fillRoundedAt(button.area, .{ .radius = button.radius, .color = fill });
    }

    const dot_space: f32 = if (button.dot != null) canvas.chrome.px(AttentionDot.diameter + AttentionDot.gap) else 0;
    const centered = button.alignment == .center;
    const inset = if (centered) @max(button.inset, dot_space) else button.inset;
    var label_area = button.area;
    label_area.x += inset;
    label_area.width = @max(0, label_area.width - 2 * inset - (if (centered) @as(f32, 0) else dot_space));
    const text_label: Label = .{
        .text = button.text,
        .color = if (button.active and button.background) palette.surface_dim else if (button.active or hovered) palette.text else palette.subtext0,
        .bold = button.bold or button.active,
        .face = button.face,
        .size = button.size,
    };
    if (button.alignment != .start and label_area.width > 0) {
        var children = [_]Item{.{ .width = .{ .fixed = @min(label_area.width, try canvas.measure(text_label)) } }};
        try (Layout{ .area = label_area, .direction = .overlay, .alignment = button.alignment }).resolve(&children);
        label_area = children[0].bounds;
    }

    _ = try canvas.textAt(label_area, text_label);
    if (button.dot) |color| {
        try (AttentionDot{ .area = button.area, .color = color }).draw(canvas);
    }

    try button.context.bands.add(.{ .area = button.area, .action = action });
}
