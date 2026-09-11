const model = @import("model.zig");
const Style = @This();

foreground: ?model.Color = null,
background: ?model.Color = null,
bold: bool = false,
italic: bool = false,
faint: bool = false,
underline: bool = false,
strikethrough: bool = false,
