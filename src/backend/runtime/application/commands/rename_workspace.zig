//! Application command for renaming a workspace aggregate.

const StateType = @import("../../../workspace/State.zig");
const RepositoryType = @import("../../../workspace/Repository.zig");
const std = @import("std");
const RenameWorkspaceEventCapture = @import("RenameWorkspaceEventCapture.zig");
const RenameWorkspaceHandler = @import("RenameWorkspaceHandler.zig");
const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const workspace_module = @import("telar-core").workspace;

fn testingRepository(state: *StateType) RepositoryType {
    return RepositoryType.init(state, std.testing.allocator);
}

test "RenameWorkspaceHandler commits before publishing one owned event" {
    var state: StateType = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location.workspace;
    const revision = workspaces.reader().revision();
    var capture: RenameWorkspaceEventCapture = .{ .reader = workspaces.reader() };
    var handler: RenameWorkspaceHandler = .{
        .workspaces = &workspaces,
        .events = capture.publisher(),
    };
    var requested_name = [_]u8{ 'b', 'a', 'c', 'k', 'e', 'n', 'd' };

    const renamed = try handler.executor().execute(.{
        .location = location,
        .name = &requested_name,
    });
    @memset(&requested_name, 'x');

    try std.testing.expectEqualStrings("backend", workspaces.reader().workspaceName(location).?);
    try std.testing.expect(workspaces.reader().revision() != revision);
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expect(capture.observed_committed_state);
    try std.testing.expectEqualDeep(location, capture.last.?.location);
    try std.testing.expectEqualStrings("backend", capture.last.?.nameSlice());
    try std.testing.expectEqualStrings("backend", renamed.nameSlice());
}

test "RenameWorkspaceHandler rejects missing targets and invalid names without effects" {
    var state: StateType = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location.workspace;
    const revision = workspaces.reader().revision();
    var capture: RenameWorkspaceEventCapture = .{ .reader = workspaces.reader() };
    var handler: RenameWorkspaceHandler = .{
        .workspaces = &workspaces,
        .events = capture.publisher(),
    };

    try std.testing.expectError(error.InvalidWorkspaceName, handler.execute(.{
        .location = location,
        .name = "",
    }));

    const oversized: [max_tab_label_bytes_module + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidWorkspaceName, handler.execute(.{
        .location = location,
        .name = &oversized,
    }));
    try std.testing.expectError(error.WorkspaceNotFound, handler.execute(.{
        .location = .{ .workspace = try workspace_module(999) },
        .name = "missing",
    }));

    try std.testing.expectEqualStrings("project", workspaces.reader().workspaceName(location).?);
    try std.testing.expectEqual(revision, workspaces.reader().revision());
    try std.testing.expectEqual(@as(usize, 0), capture.count);
    try std.testing.expect(capture.last == null);
}
