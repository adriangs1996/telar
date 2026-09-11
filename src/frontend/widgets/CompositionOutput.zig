const SemanticType = @import("Semantic.zig");
const CursorType = @import("Cursor.zig");
const Output = @This();

sidebar: SemanticType,
cursor: ?CursorType,
