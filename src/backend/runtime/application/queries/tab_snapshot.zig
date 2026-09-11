//! Application query for deciding whether a tab has a live snapshot.

const TabLocationType = @import("telar-core").TabLocation;
const workspace_module = @import("telar-core").workspace;
const tab_module = @import("telar-core").tab;
const SourceCapture = @import("SourceCapture.zig");
const TabSnapshotHandler = @import("TabSnapshotHandler.zig");
const std = @import("std");

fn testingLocation() !TabLocationType {
    return .{
        .workspace = .{ .workspace = try workspace_module(3) },
        .tab_id = try tab_module(7),
    };
}

test "Handler returns the requested live tab snapshot reference" {
    const location = try testingLocation();
    var source_capture: SourceCapture = .{ .contains = true, .pane_count = 2 };
    var handler: TabSnapshotHandler = .{ .source = source_capture.source() };

    const result = try handler.executor().execute(.{ .location = location });

    try std.testing.expectEqualDeep(location, result.location);
    try std.testing.expectEqual(@as(usize, 1), source_capture.contains_calls);
    try std.testing.expectEqual(@as(usize, 1), source_capture.pane_calls);
    try std.testing.expectEqualDeep(location, source_capture.last_location.?);
}

test "Handler rejects an absent tab without consulting panes" {
    var source_capture: SourceCapture = .{ .contains = false, .pane_count = 4 };
    var handler: TabSnapshotHandler = .{ .source = source_capture.source() };

    try std.testing.expectError(error.TabNotFound, handler.execute(.{
        .location = try testingLocation(),
    }));

    try std.testing.expectEqual(@as(usize, 1), source_capture.contains_calls);
    try std.testing.expectEqual(@as(usize, 0), source_capture.pane_calls);
}

test "Handler rejects a tab without a running pane" {
    var source_capture: SourceCapture = .{ .contains = true, .pane_count = 0 };
    var handler: TabSnapshotHandler = .{ .source = source_capture.source() };

    try std.testing.expectError(error.TabNotFound, handler.execute(.{
        .location = try testingLocation(),
    }));

    try std.testing.expectEqual(@as(usize, 1), source_capture.contains_calls);
    try std.testing.expectEqual(@as(usize, 1), source_capture.pane_calls);
}
