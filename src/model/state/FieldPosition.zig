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

pub fn changed(self: FieldPosition, field: anytype) bool {
    return self.len != field.len or self.head != field.head or self.anchor != field.anchor;
}
