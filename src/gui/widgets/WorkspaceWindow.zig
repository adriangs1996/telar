//! A centered slice of the runtime's stable workspace order. The slice is
//! derived from the current selection, so direct jumps have no navigation history.
const std = @import("std");
const WorkspaceWindow = @This();

first: usize = 0,
count: usize = 0,
total: usize = 0,

/// Keeps the active workspace in the middle until either end of the list.
/// Capacity may reduce the slice, but never expands it past three workspaces.
/// Example: `const window = WorkspaceWindow.centered(8, 4, 3);`
pub fn centered(total: usize, active: usize, capacity: usize) WorkspaceWindow {
    const count = @min(total, @min(capacity, 3));
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
pub fn previous(window: WorkspaceWindow) ?usize {
    return if (window.first == 0) null else window.first - 1;
}

/// The nearest workspace outside the slice on its right.
/// Example: `const next = window.next() orelse return;`
pub fn next(window: WorkspaceWindow) ?usize {
    const index = window.first + window.count;
    return if (index == window.total) null else index;
}

test "workspace window centers selection and clamps at both ends" {
    const starts = [_]usize{ 0, 0, 1, 2, 3, 4, 5, 5 };
    for (starts, 0..) |first, active| {
        const window = WorkspaceWindow.centered(8, active, 3);
        try std.testing.expectEqual(first, window.first);
        try std.testing.expectEqual(@as(usize, 3), window.count);
        try std.testing.expectEqual(if (first == 0) null else @as(?usize, first - 1), window.previous());
        try std.testing.expectEqual(if (first == 5) null else @as(?usize, first + 3), window.next());
    }
}

test "workspace window direct jumps and list replacement retain global positions" {
    const window = WorkspaceWindow.centered(9, 6, 3);
    try std.testing.expectEqual(@as(usize, 5), window.first);
    try std.testing.expectEqual(@as(?usize, 4), window.previous());
    try std.testing.expectEqual(@as(?usize, 8), window.next());
    const shortened = WorkspaceWindow.centered(2, 1, 3);
    try std.testing.expectEqual(@as(usize, 0), shortened.first);
    try std.testing.expectEqual(@as(usize, 2), shortened.count);
    try std.testing.expectEqual(@as(?usize, null), shortened.previous());
    try std.testing.expectEqual(@as(?usize, null), shortened.next());
}

test "workspace window includes active within every bounded capacity" {
    for (0..65) |total| {
        for (0..total + 2) |active| {
            for (0..5) |capacity| {
                const window = WorkspaceWindow.centered(total, active, capacity);
                try std.testing.expect(window.count <= 3);
                try std.testing.expect(window.first + window.count <= total);
                if (window.count != 0) {
                    const selected = @min(active, total - 1);
                    try std.testing.expect(selected >= window.first and selected < window.first + window.count);
                }
            }
        }
    }

    const compact = WorkspaceWindow.centered(8, 4, 1);
    try std.testing.expectEqual(@as(usize, 4), compact.first);
    try std.testing.expectEqual(@as(usize, 1), compact.count);
    try std.testing.expectEqual(@as(?usize, 3), compact.previous());
    try std.testing.expectEqual(@as(?usize, 5), compact.next());
}
