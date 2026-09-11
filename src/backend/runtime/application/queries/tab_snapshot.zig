//! Application query for deciding whether a tab has a live snapshot.

const std = @import("std");
const core = @import("telar-core");

pub const schema = core.schema;

pub const Request = @import("TabSnapshotRequest.zig");

pub const Result = @import("TabSnapshotResult.zig");

pub const Source = @import("Source.zig");

pub const Executor = @import("TabSnapshotExecutor.zig");

pub const Handler = @import("TabSnapshotHandler.zig");

const SourceCapture = @import("SourceCapture.zig");

fn testingLocation() !schema.TabLocation {
    return .{
        .workspace = .{ .workspace = try schema.id.workspace(3) },
        .tab_id = try schema.id.tab(7),
    };
}

test "Handler returns the requested live tab snapshot reference" {
    const location = try testingLocation();
    var source_capture: SourceCapture = .{ .contains = true, .pane_count = 2 };
    var handler: Handler = .{ .source = source_capture.source() };

    const result = try handler.executor().execute(.{ .location = location });

    try std.testing.expectEqualDeep(location, result.location);
    try std.testing.expectEqual(@as(usize, 1), source_capture.contains_calls);
    try std.testing.expectEqual(@as(usize, 1), source_capture.pane_calls);
    try std.testing.expectEqualDeep(location, source_capture.last_location.?);
}

test "Handler rejects an absent tab without consulting panes" {
    var source_capture: SourceCapture = .{ .contains = false, .pane_count = 4 };
    var handler: Handler = .{ .source = source_capture.source() };

    try std.testing.expectError(error.TabNotFound, handler.execute(.{
        .location = try testingLocation(),
    }));

    try std.testing.expectEqual(@as(usize, 1), source_capture.contains_calls);
    try std.testing.expectEqual(@as(usize, 0), source_capture.pane_calls);
}

test "Handler rejects a tab without a running pane" {
    var source_capture: SourceCapture = .{ .contains = true, .pane_count = 0 };
    var handler: Handler = .{ .source = source_capture.source() };

    try std.testing.expectError(error.TabNotFound, handler.execute(.{
        .location = try testingLocation(),
    }));

    try std.testing.expectEqual(@as(usize, 1), source_capture.contains_calls);
    try std.testing.expectEqual(@as(usize, 1), source_capture.pane_calls);
}
