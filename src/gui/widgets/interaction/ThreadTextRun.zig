//! Synchronous paint input; text is borrowed only while geometry is appended.
const MessageLayoutOwner = @import("../MessageLayoutOwner.zig");
const Rect = @import("../../render/Rect.zig");
const Label = @import("../Label.zig");

owner: MessageLayoutOwner,
offset: u32,
text: []const u8,
bounds: Rect,
viewport: Rect,
advance: f32,
face: @FieldType(Label, "face"),
bold: bool = false,
pixel_height: u16,
