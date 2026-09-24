const EditorDisplay = @import("interaction/EditorDisplay.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const EditorFont = @import("interaction/EditorFont.zig");

display: *const EditorDisplay,
content: Rect,
columns: u16,
font: ?EditorFont = null,
