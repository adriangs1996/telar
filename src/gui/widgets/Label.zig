const label_face = @import("label_face.zig");
const label_size = @import("label_size.zig");
const core = @import("telar-core");

text: []const u8,
color: core.Color = .default,
bold: bool = false,
italic: bool = false,
faint: bool = false,
/// Straight alpha multiplied into the ink; the working pulse steps it.
alpha: f32 = 1,
underline: bool = false,
strikethrough: bool = false,
face: label_face.Face = .mono,
/// The chrome text size a sans label is set at; monospace labels keep the cell size.
size: label_size.Size = .terminal,
