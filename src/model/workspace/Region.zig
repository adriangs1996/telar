const cellgrid = @import("cellgrid");
const std = @import("std");
/// The workbench cell grid an adapter publishes for the active tab: the TUI
/// derives it from its terminal size and chrome, a GUI from its window, font
/// metrics and native chrome. The model lays panes out inside it in cells.
const Region = @This();

area: cellgrid.Rect,
revision: u64,

/// Rejects input captured before a workbench-grid change, including ABA.
/// Example: `if (!captured.matches(current)) return;`.
pub fn matches(self: Region, current: Region) bool {
    return self.revision == current.revision and std.meta.eql(self.area, current.area);
}
