const std = @import("std");
const id = @import("../id.zig");
/// Selection coordinates use the full screen history, not viewport rows.
const CopySelection = @This();

pane_id: id.PaneId,
start_x: u16,
start_y: u32,
end_x: u16,
end_y: u32,
linewise: bool = false,

/// Parses inclusive history coordinates without allocating. Example: `const range = try CopySelection.fromText(pane, "0,10:79,12");`
pub fn fromText(pane_id: id.PaneId, text: []const u8) !CopySelection {
    if (pane_id == .invalid) {
        return error.InvalidPaneId;
    }

    var endpoints = std.mem.splitScalar(u8, text, ':');
    var start = std.mem.splitScalar(u8, endpoints.next() orelse return error.InvalidCopyRange, ',');
    var finish = std.mem.splitScalar(u8, endpoints.next() orelse return error.InvalidCopyRange, ',');
    const selection: CopySelection = .{
        .pane_id = pane_id,
        .start_x = std.fmt.parseUnsigned(u16, start.next() orelse return error.InvalidCopyRange, 10) catch return error.InvalidCopyRange,
        .start_y = std.fmt.parseUnsigned(u32, start.next() orelse return error.InvalidCopyRange, 10) catch return error.InvalidCopyRange,
        .end_x = std.fmt.parseUnsigned(u16, finish.next() orelse return error.InvalidCopyRange, 10) catch return error.InvalidCopyRange,
        .end_y = std.fmt.parseUnsigned(u32, finish.next() orelse return error.InvalidCopyRange, 10) catch return error.InvalidCopyRange,
    };
    if (endpoints.next() != null or start.next() != null or finish.next() != null) {
        return error.InvalidCopyRange;
    }

    return selection;
}

test "copy ranges preserve absolute history rows and reject malformed coordinates" {
    const selection = try fromText(@enumFromInt(1), "0,1000:79,1002");
    try std.testing.expectEqual(@as(u32, 1000), selection.start_y);
    try std.testing.expectEqual(@as(u16, 79), selection.end_x);
    try std.testing.expectError(error.InvalidCopyRange, fromText(@enumFromInt(1), "0,1:65536,2"));
    try std.testing.expectError(error.InvalidCopyRange, fromText(@enumFromInt(1), "0,,1:2,3"));
    try std.testing.expectError(error.InvalidCopyRange, fromText(@enumFromInt(1), "0,1:2,3:4,5"));
}
