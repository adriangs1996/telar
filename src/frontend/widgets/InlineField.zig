//! One single-row field of the inline new-context form.
const RectType = @import("telar-core").Rect;
const InlineField = @This();

area: RectType,
text: []const u8,
focused: bool,
