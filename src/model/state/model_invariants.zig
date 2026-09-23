//! Invariants that span the client model's tables. Tests run `check` after
//! their steps; production code never pays for it.
const std = @import("std");
const ClientModel = @import("ClientModel.zig");

/// Fails when the tables disagree: an active slot past the last tab, a tab
/// the index cannot find, a pane record the index does not return, a pane
/// count that is not the number of records, or a focused pane missing from
/// its tab's layout.
///
/// ```zig
/// try model_invariants.check(&model);
/// ```
pub fn check(model: *const ClientModel) !void {
    const tabs = &model.tabs;
    if (tabs.count > tabs.location.len or (tabs.count != 0 and tabs.active >= tabs.count)) {
        return error.BrokenTabsInvariant;
    }

    for (0..tabs.count) |slot| {
        if (tabs.find(tabs.location[slot].tab_id) != slot) {
            return error.BrokenTabsInvariant;
        }

        const focused = tabs.layout[slot].focused() orelse continue;
        if (!tabs.layout[slot].contains(focused)) {
            return error.BrokenLayoutInvariant;
        }
    }

    var records: usize = 0;
    for (model.panes.record) |maybe_pane| {
        const pane = maybe_pane orelse continue;
        records += 1;
        if (model.panes.findConst(pane.id) != pane) {
            return error.BrokenPanesInvariant;
        }
    }

    if (records != model.panes.count) {
        return error.BrokenPanesInvariant;
    }
}

test "a fresh model satisfies every invariant" {
    var model = ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    try check(&model);
}
