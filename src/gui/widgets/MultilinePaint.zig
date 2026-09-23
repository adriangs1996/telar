const EditorDisplay = @import("interaction/EditorDisplay.zig");
const Rect = @import("../render/Rect.zig");
const EditorFont = @import("interaction/EditorFont.zig");

display: *const EditorDisplay,
content: Rect,
columns: u16,
font: ?EditorFont = null,
