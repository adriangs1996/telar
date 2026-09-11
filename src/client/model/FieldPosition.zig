const FieldPosition = @This();
const source_namespace = @import("name_prompt.zig");
len: usize,
head: usize,
anchor: usize,

pub fn capture(field: *const source_namespace.Field) FieldPosition {
    return .{
        .len = field.len,
        .head = field.head,
        .anchor = field.anchor,
    };
}

pub fn changed(before: FieldPosition, field: *const source_namespace.Field) bool {
    return before.len != field.len or before.head != field.head or before.anchor != field.anchor;
}
