const max_panes_per_tab = @import("telar-core").max_panes_per_tab;
const PaneType = @import("../panes/Pane.zig");
/// Iterates the live panes without exposing the slot array.
const PaneIterator = @This();

panes: *[max_panes_per_tab]?PaneType,
index: usize = 0,

pub fn next(iterator: *PaneIterator) ?*PaneType {
    while (iterator.index < max_panes_per_tab) {
        const slot = &iterator.panes[iterator.index];
        iterator.index += 1;
        if (slot.*) |*pane| {
            return pane;
        }
    }
    return null;
}
