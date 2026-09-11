const Region = @This();
const ui = @import("telar-core").ui;
const std = @import("std");
area: ui.Rect,
revision: u64,

/// Rejects input captured before a host-region change, including ABA.
/// Example: `if (!captured.matches(current)) return;`.
pub fn matches(captured: Region, current: Region) bool {
    return captured.revision == current.revision and std.meta.eql(captured.area, current.area);
}
