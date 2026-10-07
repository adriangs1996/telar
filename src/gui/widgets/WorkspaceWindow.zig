//! A centered slice of the runtime's stable workspace order. The slice is
//! derived from the current selection, so direct jumps have no navigation history.
const WorkspaceWindow = @This();

first: usize = 0,
count: usize = 0,
total: usize = 0,

/// Keeps the active workspace in the middle until either end of the list.
/// Capacity follows the available width, without a fixed project-count limit.
/// Example: `const window = WorkspaceWindow.centered(8, 4, 3);`
pub fn centered(total: usize, active: usize, capacity: usize) WorkspaceWindow {
    const count = @min(total, capacity);
    if (count == 0) {
        return .{ .total = total };
    }

    const selected = @min(active, total - 1);
    return .{
        .first = @min(selected -| count / 2, total - count),
        .count = count,
        .total = total,
    };
}

/// The nearest workspace outside the slice on its left.
/// Example: `const previous = window.previous() orelse return;`
pub fn previous(self: WorkspaceWindow) ?usize {
    return if (self.first == 0) null else self.first - 1;
}

/// The nearest workspace outside the slice on its right.
/// Example: `const next = window.next() orelse return;`
pub fn next(self: WorkspaceWindow) ?usize {
    const index = self.first + self.count;
    return if (index == self.total) null else index;
}
