const Color = @import("telar-core").Color;

text: []const u8,
color: Color = .default,
bold: bool = false,
italic: bool = false,
faint: bool = false,
/// Straight alpha multiplied into the ink; the working pulse steps it.
alpha: f32 = 1,
underline: bool = false,
strikethrough: bool = false,
face: @import("label_face.zig").Face = .mono,
/// The chrome text size a sans label is set at; monospace labels keep the cell size.
size: @import("label_size.zig").Size = .terminal,
