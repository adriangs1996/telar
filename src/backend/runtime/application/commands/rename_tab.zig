//! Application command for renaming a tab aggregate.

const std = @import("std");
const core = @import("telar-core");
const workspace_mod = @import("../../../workspace/root.zig");

pub const schema = core.schema;
pub const WorkspaceRepository = workspace_mod.Repository;

pub const RenameTab = @import("RenameTab.zig");

pub const RenameTabResult = workspace_mod.TabRenamed;

pub const EventPublisher = @import("RenameTabEventPublisher.zig");

pub const RenameTabExecutor = @import("RenameTabExecutor.zig");

pub const RenameTabHandler = @import("RenameTabHandler.zig");

const EventCapture = @import("RenameTabEventCapture.zig");

fn testingRepository(state: *workspace_mod.State) WorkspaceRepository {
    return WorkspaceRepository.init(state, std.testing.allocator);
}

test "RenameTabHandler commits before publishing one owned event" {
    var state: workspace_mod.State = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    const revision = workspaces.reader().revision();
    var capture: EventCapture = .{ .reader = workspaces.reader() };
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
    var state: workspace_mod.State = .{};
    var workspaces = testingRepository(&state);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    const revision = workspaces.reader().revision();
    var capture: EventCapture = .{ .reader = workspaces.reader() };
    var handler: RenameTabHandler = .{
        .workspaces = &workspaces,
        .events = capture.publisher(),
    };

    try std.testing.expectError(error.InvalidTabLabel, handler.execute(.{
        .location = location,
        .label = "",
    }));

    const oversized: [schema.max_tab_label_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidTabLabel, handler.execute(.{
        .location = location,
        .label = &oversized,
    }));

    var missing_tab = location;
    missing_tab.tab_id = try schema.id.tab(999);
    try std.testing.expectError(error.TabNotFound, handler.execute(.{
        .location = missing_tab,
        .label = "missing",
    }));

    const missing_workspace: schema.TabLocation = .{
        .workspace = .{ .workspace = try schema.id.workspace(999) },
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
