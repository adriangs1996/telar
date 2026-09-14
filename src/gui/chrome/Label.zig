const Color = @import("telar-core").Color;

text: []const u8,
color: Color = .default,
bold: bool = false,
italic: bool = false,
faint: bool = false,
underline: bool = false,
strikethrough: bool = false,
face: @import("label_face.zig").Face = .mono,
