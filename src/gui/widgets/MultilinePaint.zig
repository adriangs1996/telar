const EditorDisplay = @import("interaction/EditorDisplay.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;

display: *const EditorDisplay,
content: Rect,
columns: u16,
