//! A chrome control in device pixels with one semantic intent.
const gfx = @import("gfx");
const alignment_module = gfx.alignment;
const label_face = @import("label_face.zig");
const label_size = @import("label_size.zig");
const action_module = @import("action.zig");
const core = @import("telar-core");
const client = @import("telar-client");
const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
const Label = @import("Label.zig");
const AttentionDot = @import("AttentionDot.zig");
const Layout = gfx.Layout;
const Item = gfx.Item;
const Rect = gfx.Rect;
const PixelButton = @This();

context: *const Context,
area: Rect,
intent: client.Intent,
text: []const u8,
active: bool = false,
background: bool = true,
alignment: alignment_module.Alignment = .start,
radius: f32 = 999,
bold: bool = false,
face: label_face.Face = .sans,
size: label_size.Size = .body,
/// Horizontal inset of the label inside the control, in device pixels.
inset: f32 = 0,
/// An attention dot painted at the trailing edge in this color, if any.
dot: ?core.Color = null,

/// Paints and registers a pixel control. Plain controls retain a clear
/// background on hover; centered labels reserve equal space around their dot.
/// Example: `try button.draw(canvas);`
pub fn draw(self: PixelButton, canvas: *Canvas) !void {
    if (self.area.width <= 0 or self.area.height <= 0) {
        return;
    }

    const palette = canvas.theme.palette;
    const action: action_module.Action = .{ .intent = self.intent };
    const hovered = self.context.isHovered(action);

    if (self.background) {
        const fill: core.Color = if (self.active) palette.accent else if (hovered) palette.surface1 else palette.surface0;
        try canvas.fillRoundedAt(self.area, .{ .radius = self.radius, .color = fill });
    }

    const dot_space: f32 = if (self.dot != null) canvas.chrome.px(AttentionDot.diameter + AttentionDot.gap) else 0;
    const centered = self.alignment == .center;
    const inset = if (centered) @max(self.inset, dot_space) else self.inset;
    var label_area = self.area;
    label_area.x += inset;
    label_area.width = @max(0, label_area.width - 2 * inset - (if (centered) @as(f32, 0) else dot_space));

    const text_label: Label = .{
        .text = self.text,
        .color = if (self.active and self.background) palette.surface_dim else if (self.active or hovered) palette.text else palette.subtext0,
        .bold = self.bold or self.active,
        .face = self.face,
        .size = self.size,
    };

    if (self.alignment != .start and label_area.width > 0) {
        var children = [_]Item{.{
            .width = .{
                .fixed = @min(label_area.width, try canvas.measure(text_label)),
            },
        }};

        try (Layout{
            .area = label_area,
            .direction = .overlay,
            .alignment = self.alignment,
        }).resolve(&children);

        label_area = children[0].bounds;
    }

    _ = try canvas.textAt(label_area, text_label);

    if (self.dot) |color| {
        try (AttentionDot{
            .area = self.area,
            .color = color,
        }).draw(canvas);
    }

    try self.context.bands.add(.{
        .area = self.area,
        .action = action,
    });
}
