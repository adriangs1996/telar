//! Application use case for applying one canonical tab snapshot.

const TabSnapshotTestingModel = @import("TabSnapshotTestingModel.zig");
const TabSnapshotEffectsCapture = @import("TabSnapshotEffectsCapture.zig");
const ApplyTabSnapshotHandler = @import("ApplyTabSnapshotHandler.zig");
const std = @import("std");
const PaneSnapshot = @import("../../workspace/PaneSnapshot.zig");
const VersionType = @import("../../model/Version.zig");

test "ApplyTabSnapshotHandler commits before delivering client resources" {
    var testing = try TabSnapshotTestingModel.init();
    defer testing.deinit();
    var capture: TabSnapshotEffectsCapture = .{
        .model = testing.model,
        .expected_pane = testing.discovered_pane,
    };
    var handler: ApplyTabSnapshotHandler = .{
        .model = testing.model,
        .area = .{ .w = 40, .h = 10 },
        .effects = capture.port(),
    };
    try handler.execute(testing.snapshot());

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.observed_commit);
    try std.testing.expect(capture.active);
    try std.testing.expect(capture.panes_changed);
}

test "ApplyTabSnapshotHandler still runs resource effects for a canonical no-op" {
    var testing = try TabSnapshotTestingModel.init();
    defer testing.deinit();
    var capture: TabSnapshotEffectsCapture = .{
        .model = testing.model,
        .expected_pane = testing.discovered_pane,
    };
    var handler: ApplyTabSnapshotHandler = .{
        .model = testing.model,
        .area = .{ .w = 40, .h = 10 },
        .effects = capture.port(),
    };
    const snapshot = testing.snapshot();
    try handler.execute(snapshot);
    const committed_version = testing.model.version();

    try handler.execute(snapshot);

    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    try std.testing.expect(!capture.panes_changed);
    try std.testing.expectEqualDeep(committed_version, testing.model.version());
}

test "ApplyTabSnapshotHandler rejects model failures before effects" {
    var testing = try TabSnapshotTestingModel.init();
    defer testing.deinit();
    var capture: TabSnapshotEffectsCapture = .{
        .model = testing.model,
        .expected_pane = testing.discovered_pane,
    };
    var handler: ApplyTabSnapshotHandler = .{
        .model = testing.model,
        .area = .{ .w = 40, .h = 10 },
        .effects = capture.port(),
    };
    const snapshot: PaneSnapshot = .{
        .location = .{
            .workspace = testing.location.workspace,
            .tab_id = @enumFromInt(9),
        },
        .panes = &.{testing.root_pane},
    };

    try std.testing.expectError(error.UnexpectedTab, handler.execute(snapshot));

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "ApplyTabSnapshotHandler preserves a committed snapshot after effect failure" {
    var testing = try TabSnapshotTestingModel.init();
    defer testing.deinit();
    var capture: TabSnapshotEffectsCapture = .{
        .model = testing.model,
        .expected_pane = testing.discovered_pane,
        .fail = true,
    };
    var handler: ApplyTabSnapshotHandler = .{
        .model = testing.model,
        .area = .{ .w = 40, .h = 10 },
        .effects = capture.port(),
    };
    try std.testing.expectError(error.ReconciliationSyncFailed, handler.execute(testing.snapshot()));

    try std.testing.expect(capture.observed_commit);
    try std.testing.expect(testing.model.workspace.findPane(testing.discovered_pane) != null);
    try std.testing.expectEqual(@as(u64, 1), testing.model.version().panes);
}
