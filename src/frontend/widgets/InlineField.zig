//! One single-row field of the inline new-context form.
const core = @import("telar-core");
const InlineField = @This();

area: core.Rect,
text: []const u8,
focused: bool,
