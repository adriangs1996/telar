//! A rounded chrome control in device pixels with one semantic intent.
const core = @import("telar-core");
const client = @import("telar-client");

area: @import("../render/Rect.zig"),
intent: client.Intent,
text: []const u8,
active: bool = false,
radius: f32 = 999,
bold: bool = false,
face: @import("label_face.zig").Face = .sans,
/// Horizontal inset of the label inside the control, in device pixels.
inset: f32 = 0,
/// An attention dot painted at the trailing edge in this color, if any.
dot: ?core.Color = null,
