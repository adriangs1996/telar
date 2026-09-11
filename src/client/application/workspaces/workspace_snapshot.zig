//! Application use case for applying one canonical workspace snapshot.

const WorkspaceSnapshotTestingModel = @import("WorkspaceSnapshotTestingModel.zig");
const WorkspaceSnapshotEffectsCapture = @import("WorkspaceSnapshotEffectsCapture.zig");
const ApplyWorkspaceSnapshotHandler = @import("ApplyWorkspaceSnapshotHandler.zig");
const std = @import("std");
const WorkspaceSnapshotInput = @import("../../workspace/WorkspaceSnapshotInput.zig");
const VersionType = @import("../../model/Version.zig");

test "ApplyWorkspaceSnapshotHandler commits before delivering client resources" {
    var testing = try WorkspaceSnapshotTestingModel.init();
    defer testing.deinit();
    var capture: WorkspaceSnapshotEffectsCapture = .{ .model = testing.model };
    var handler: ApplyWorkspaceSnapshotHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };
    try handler.execute(testing.snapshot());

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(@as(usize, 1), capture.removed_tabs);
    try std.testing.expectEqual(@as(usize, 1), capture.removed_panes);
    try std.testing.expect(capture.active_changed);
    try std.testing.expectEqualDeep(testing.first, testing.model.activeTabLocation().?);
}

test "ApplyWorkspaceSnapshotHandler still runs resource effects for a canonical no-op" {
    var testing = try WorkspaceSnapshotTestingModel.init();
    defer testing.deinit();
    var capture: WorkspaceSnapshotEffectsCapture = .{ .model = testing.model };
    var handler: ApplyWorkspaceSnapshotHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };
    const snapshot = testing.snapshot();
    try handler.execute(snapshot);
    const committed_version = testing.model.version();

    try handler.execute(snapshot);

    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    try std.testing.expectEqual(@as(usize, 0), capture.removed_tabs);
    try std.testing.expectEqual(@as(usize, 0), capture.removed_panes);
    try std.testing.expect(!capture.active_changed);
    try std.testing.expectEqualDeep(committed_version, testing.model.version());
}

test "ApplyWorkspaceSnapshotHandler rejects model failures before effects" {
    var testing = try WorkspaceSnapshotTestingModel.init();
    defer testing.deinit();
    var capture: WorkspaceSnapshotEffectsCapture = .{ .model = testing.model };
    var handler: ApplyWorkspaceSnapshotHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };
    const snapshot: WorkspaceSnapshotInput = .{
        .workspace = .{ .workspace = @enumFromInt(9) },
        .name = "wrong",
        .tabs = &.{
            .{ .tab_id = testing.first.tab_id, .pane_count = 1, .label = "main" },
        },
    };

    try std.testing.expectError(error.UnexpectedWorkspace, handler.execute(snapshot));

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expectEqual(@as(usize, 2), testing.model.workspace.count);
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "ApplyWorkspaceSnapshotHandler preserves a committed snapshot after effect failure" {
    var testing = try WorkspaceSnapshotTestingModel.init();
    defer testing.deinit();
    var capture: WorkspaceSnapshotEffectsCapture = .{ .model = testing.model, .fail = true };
    var handler: ApplyWorkspaceSnapshotHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };
    try std.testing.expectError(error.ReconciliationSyncFailed, handler.execute(testing.snapshot()));

    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqualStrings("renamed", testing.model.workspace.workspaceName());
    try std.testing.expectEqual(@as(usize, 1), testing.model.workspace.count);
}
