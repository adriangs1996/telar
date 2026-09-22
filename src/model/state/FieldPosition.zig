const FieldPosition = @This();

len: usize,
head: usize,
anchor: usize,

/// Snapshots either prompt field. Example: `const before: FieldPosition = .capture(&prompt.directory);`
pub fn capture(field: anytype) FieldPosition {
    return .{
        .len = field.len,
        .head = field.head,
        .anchor = field.anchor,
    };
}

pub fn changed(before: FieldPosition, field: anytype) bool {
    return before.len != field.len or before.head != field.head or before.anchor != field.anchor;
}
