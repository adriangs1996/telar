//! Stable client-local widget identity. Replacing its owner increments the
//! generation; changing frame order or geometry never changes the identity.
const Id = @This();

target_id: u64 = 0,
generation: u64 = 0,

/// Example: `if (focused.eql(target.id)) drawFocus();`
pub fn eql(self: Id, right: Id) bool {
    return self.target_id == right.target_id and self.generation == right.generation;
}
