//! Stable client-local widget identity. Replacing its owner increments the
//! generation; changing frame order or geometry never changes the identity.
const Id = @This();

target_id: u64 = 0,
generation: u64 = 0,

/// Example: `if (focused.eql(target.id)) drawFocus();`
pub fn eql(left: Id, right: Id) bool {
    return left.target_id == right.target_id and left.generation == right.generation;
}
