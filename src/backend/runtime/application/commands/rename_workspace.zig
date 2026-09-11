//! Application command for renaming a workspace aggregate.

const std = @import("std");
const core = @import("telar-core");
const workspace_mod = @import("../../../workspace/root.zig");

pub const schema = core.schema;
pub const WorkspaceRepository = workspace_mod.Repository;

pub const RenameWorkspace = @import("RenameWorkspace.zig");

pub const RenameWorkspaceResult = workspace_mod.WorkspaceRenamed;

pub const EventPublisher = @import("RenameWorkspaceEventPublisher.zig");

pub const RenameWorkspaceExecutor = @import("RenameWorkspaceExecutor.zig");

pub const RenameWorkspaceHandler = @import("RenameWorkspaceHandler.zig");

const EventCapture = @import("RenameWorkspaceEventCapture.zig");

fn testingRepository(state: *workspace_mod.State) WorkspaceRepository {
    return WorkspaceRepository.init(state, std.testing.allocator);
}

test "RenameWorkspaceHandler commits before publishing one owned event" {
    var state: workspace_mod.State = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location.workspace;
    const revision = workspaces.reader().revision();
    var capture: EventCapture = .{ .reader = workspaces.reader() };
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
    var state: workspace_mod.State = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location.workspace;
    const revision = workspaces.reader().revision();
    var capture: EventCapture = .{ .reader = workspaces.reader() };
    var handler: RenameWorkspaceHandler = .{
        .workspaces = &workspaces,
        .events = capture.publisher(),
    };

    try std.testing.expectError(error.InvalidWorkspaceName, handler.execute(.{
        .location = location,
        .name = "",
    }));

    const oversized: [schema.max_tab_label_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidWorkspaceName, handler.execute(.{
        .location = location,
        .name = &oversized,
    }));
    try std.testing.expectError(error.WorkspaceNotFound, handler.execute(.{
        .location = .{ .workspace = try schema.id.workspace(999) },
        .name = "missing",
    }));

    try std.testing.expectEqualStrings("project", workspaces.reader().workspaceName(location).?);
    try std.testing.expectEqual(revision, workspaces.reader().revision());
    try std.testing.expectEqual(@as(usize, 0), capture.count);
    try std.testing.expect(capture.last == null);
}
