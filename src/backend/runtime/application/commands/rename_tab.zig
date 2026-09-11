//! Application command for renaming a tab aggregate.

const StateType = @import("../../../workspace/State.zig");
const RepositoryType = @import("../../../workspace/Repository.zig");
const std = @import("std");
const RenameTabEventCapture = @import("RenameTabEventCapture.zig");
const RenameTabHandler = @import("RenameTabHandler.zig");
const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const tab_module = @import("telar-core").tab;
const TabLocationType = @import("telar-core").TabLocation;
const workspace_module = @import("telar-core").workspace;

fn testingRepository(state: *StateType) RepositoryType {
    return RepositoryType.init(state, std.testing.allocator);
}

test "RenameTabHandler commits before publishing one owned event" {
    var state: StateType = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    const revision = workspaces.reader().revision();
    var capture: RenameTabEventCapture = .{ .reader = workspaces.reader() };
    var handler: RenameTabHandler = .{
        .workspaces = &workspaces,
        .events = capture.publisher(),
    };
    const executor = handler.executor();
    var requested_label = [_]u8{ 's', 'e', 'r', 'v', 'e', 'r' };

    const renamed = try executor.execute(.{
        .location = location,
        .label = &requested_label,
    });
    @memset(&requested_label, 'x');

    try std.testing.expectEqualStrings("server", workspaces.reader().tabLabel(location).?);
    try std.testing.expectEqual(revision, workspaces.reader().revision());
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expect(capture.observed_committed_state);
    try std.testing.expectEqualDeep(location, capture.last.?.location);
    try std.testing.expectEqualStrings("server", capture.last.?.labelSlice());
    try std.testing.expectEqualStrings("server", renamed.labelSlice());
}

test "RenameTabHandler rejects invalid targets and labels without effects" {
    var state: StateType = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    const revision = workspaces.reader().revision();
    var capture: RenameTabEventCapture = .{ .reader = workspaces.reader() };
    var handler: RenameTabHandler = .{
        .workspaces = &workspaces,
        .events = capture.publisher(),
    };

    try std.testing.expectError(error.InvalidTabLabel, handler.execute(.{
        .location = location,
        .label = "",
    }));

    const oversized: [max_tab_label_bytes_module + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidTabLabel, handler.execute(.{
        .location = location,
        .label = &oversized,
    }));

    var missing_tab = location;
    missing_tab.tab_id = try tab_module(999);
    try std.testing.expectError(error.TabNotFound, handler.execute(.{
        .location = missing_tab,
        .label = "missing",
    }));

    const missing_workspace: TabLocationType = .{
        .workspace = .{ .workspace = try workspace_module(999) },
        .tab_id = location.tab_id,
    };
    try std.testing.expectError(error.TabNotFound, handler.execute(.{
        .location = missing_workspace,
        .label = "missing",
    }));

    try std.testing.expectEqualStrings("main", workspaces.reader().tabLabel(location).?);
    try std.testing.expectEqual(revision, workspaces.reader().revision());
    try std.testing.expectEqual(@as(usize, 0), capture.count);
    try std.testing.expect(capture.last == null);
}
