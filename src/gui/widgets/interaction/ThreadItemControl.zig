//! A delivered conversation action owns an item identity, never a row index.
const Control = @This();

pane_id: @import("telar-core").PaneId,
attachment_generation: u64,
identity: u64,
source_key: u64 = 0,
operation: enum { toggle, toggle_work, copy } = .toggle,

/// Expansion and copy share the same item owner. Example: `if (a.sameItem(b)) ...`
pub fn sameItem(left: Control, right: Control) bool {
    if ((left.operation == .toggle_work) != (right.operation == .toggle_work)) {
        return false;
    }

    return left.pane_id == right.pane_id and left.attachment_generation == right.attachment_generation and (if (left.source_key != 0 and right.source_key != 0) left.source_key == right.source_key else left.identity == right.identity);
}
