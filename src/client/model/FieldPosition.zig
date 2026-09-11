const name_prompt = @import("name_prompt.zig");
const FieldPosition = @This();

len: usize,
head: usize,
anchor: usize,

pub fn capture(field: *const name_prompt.Field) FieldPosition {
    return .{
        .len = field.len,
        .head = field.head,
        .anchor = field.anchor,
    };
}

pub fn changed(before: FieldPosition, field: *const name_prompt.Field) bool {
    return before.len != field.len or before.head != field.head or before.anchor != field.anchor;
}
