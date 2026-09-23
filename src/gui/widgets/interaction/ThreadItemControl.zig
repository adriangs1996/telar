//! A delivered conversation action owns an item identity, never a row index.
const core = @import("telar-core");
const Control = @This();

pane_id: core.PaneId,
attachment_generation: u64,
identity: u64,
source_key: u64 = 0,
operation: enum { toggle, toggle_work, copy } = .toggle,

/// Expansion and copy share the same item owner. Example: `if (a.sameItem(b)) ...`
pub fn sameItem(self: Control, right: Control) bool {
    if ((self.operation == .toggle_work) != (right.operation == .toggle_work)) {
        return false;
    }

    return self.pane_id == right.pane_id and self.attachment_generation == right.attachment_generation and (if (self.source_key != 0 and right.source_key != 0) self.source_key == right.source_key else self.identity == right.identity);
}
