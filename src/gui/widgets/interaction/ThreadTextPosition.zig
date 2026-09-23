//! One source caret in the immutable reading window, independent of screen rows.
const MessageLayoutOwner = @import("../MessageLayoutOwner.zig");

const Position = @This();
owner: MessageLayoutOwner,
order: u16,
offset: u32,

/// Example: `if (a.before(b)) select(a, b);`
pub fn before(self: Position, b: Position) bool {
    if (self.order != b.order) {
        return self.order < b.order;
    }
    if (self.owner.section != b.owner.section) {
        return self.owner.section == .metadata;
    }
    return self.offset < b.offset;
}

/// Example: `if (anchor.eql(head)) hideHighlight();`
pub fn eql(self: Position, b: Position) bool {
    return self.order == b.order and self.offset == b.offset and self.owner.section == b.owner.section and self.owner.item_identity == b.owner.item_identity and self.owner.pane_id == b.owner.pane_id and self.owner.attachment_generation == b.owner.attachment_generation;
}
