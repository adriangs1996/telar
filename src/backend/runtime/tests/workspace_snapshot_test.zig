//! Vertical contract tests for the runtime workspace-snapshot flow.

const StateType = @import("../../workspace/State.zig");
const RepositoryType = @import("../../workspace/Repository.zig");
const std = @import("std");
const WorkspaceSnapshotHandler = @import("../application/queries/WorkspaceSnapshotHandler.zig");
const ResponseQueueType = @import("../delivery/ResponseQueue.zig");
const WorkspaceSnapshotController = @import("../entrypoints/requests/WorkspaceSnapshotController.zig");
const RequestIdType = @import("telar-core").RequestId;
const RuntimeStateFixture = @import("RuntimeStateFixture.zig");
const PaneFixture = @import("PaneFixture.zig");
const TabLocation = @import("telar-core").TabLocation;

test "workspace delivery includes distinct foreground names for tabs without attachments" {
    const fixture = try RuntimeStateFixture.create();
    defer fixture.destroy();
    var pane_fixture: PaneFixture = .{};
    try pane_fixture.init();
    defer pane_fixture.deinit();
    var workspaces = RepositoryType.init(&fixture.workspaces, std.testing.allocator);
    defer workspaces.deinit();
    const first = try workspaces.restoreWorkspace(.{
        .id = PaneFixture.location.workspace.workspace,
        .path = "/work/project",
        .explicit_name = null,
        .first_tab_id = PaneFixture.location.tab_id,
        .first_tab_label = "",
    });
    const second: TabLocation = .{ .workspace = first.workspace, .tab_id = @enumFromInt(6) };
    try workspaces.restoreTab(second, "logs");
    const other_pane = try pane_fixture.createPane(@enumFromInt(8));
    defer {
        other_pane.session.shutdown();
        other_pane.destroy();
    }

    other_pane.location = second;
    pane_fixture.pane.agent_process_cache.setName("nvim");
    other_pane.agent_process_cache.setName("codex");
    try fixture.panes.insert(pane_fixture.pane);
    try fixture.panes.insert(other_pane);
    var handler: WorkspaceSnapshotHandler = .{ .workspaces = workspaces.reader() };
    var controller = WorkspaceSnapshotController.init(&fixture.delivery.responses, handler.executor());
    try controller.requestWorkspaceSnapshot(.{ .request_id = @enumFromInt(41), .workspace = first.workspace });
    const delivered = (try fixture.next()).?.workspace_snapshot;
    var tabs = delivered.tabs();
    const first_tab = (try tabs.next()).?;
    const second_tab = (try tabs.next()).?;
    try std.testing.expectEqualStrings("", first_tab.label);
    try std.testing.expectEqualStrings("logs", second_tab.label);
    var first_names = first_tab.foregrounds();
    var second_names = second_tab.foregrounds();
    const first_name = (try first_names.next()).?;
    const second_name = (try second_names.next()).?;
    try std.testing.expectEqual(pane_fixture.pane.id, first_name.pane_id);
    try std.testing.expectEqualStrings("nvim", first_name.name);
    try std.testing.expectEqual(other_pane.id, second_name.pane_id);
    try std.testing.expectEqualStrings("codex", second_name.name);
    try std.testing.expect((try first_names.next()) == null);
    try std.testing.expect((try second_names.next()) == null);
    try std.testing.expect((try tabs.next()) == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.attachments.count);
}

test "an aggregate crosses workspace query and controller boundaries" {
    var state: StateType = .{};
    var workspaces = RepositoryType.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location.workspace;
    var handler: WorkspaceSnapshotHandler = .{ .workspaces = workspaces.reader() };
    var responses: ResponseQueueType = .{};
    var controller = WorkspaceSnapshotController.init(&responses, handler.executor());
    const request_id: RequestIdType = @enumFromInt(41);

    try controller.requestWorkspaceSnapshot(.{
        .request_id = request_id,
        .workspace = location,
    });

    const response = responses.peek().?;
    try std.testing.expect(response.* == .workspace_snapshot);
    try std.testing.expectEqual(request_id, response.workspace_snapshot.request_id);
    try std.testing.expectEqualDeep(location, response.workspace_snapshot.workspace);
}
