//! One source caret in the immutable reading window, independent of screen rows.
const Position = @This();
owner: @import("../MessageLayoutOwner.zig"),
order: u16,
offset: u32,

/// Example: `if (a.before(b)) select(a, b);`
pub fn before(a: Position, b: Position) bool {
    if (a.order != b.order) {
        return a.order < b.order;
    }
    if (a.owner.section != b.owner.section) {
        return a.owner.section == .metadata;
    }
    return a.offset < b.offset;
}

/// Example: `if (anchor.eql(head)) hideHighlight();`
pub fn eql(a: Position, b: Position) bool {
    return a.order == b.order and a.offset == b.offset and a.owner.section == b.owner.section and a.owner.item_identity == b.owner.item_identity and a.owner.pane_id == b.owner.pane_id and a.owner.attachment_generation == b.owner.attachment_generation;
}
