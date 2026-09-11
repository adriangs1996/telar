//! Application use case for changing one client's active tab.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../root.zig").model;

pub const schema = core.schema;

pub const Target = client_model.TabSelectionTarget;

pub const SelectTab = @import("SelectTab.zig");

pub const SnapshotGate = @import("SnapshotGate.zig");

pub const SelectionEffects = @import("SelectionEffects.zig");

pub const SelectTabHandler = @import("SelectTabHandler.zig");

const SnapshotGateCapture = @import("SnapshotGateCapture.zig");

const EffectsCapture = @import("SelectTabEffectsCapture.zig");

const TestingModel = @import("SelectTabTestingModel.zig");

test "SelectTabHandler commits a resolved target before synchronizing resources" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var snapshots: SnapshotGateCapture = .{};
    var effects: EffectsCapture = .{ .model = testing.model, .expected = testing.second };
    var handler: SelectTabHandler = .{
        .model = testing.model,
        .snapshots = snapshots.port(),
        .effects = effects.port(),
    };

    const selection = (try handler.execute(.{ .target = .{ .position = 1 } })).?;

    try std.testing.expectEqualDeep(testing.first, selection.previous);
    try std.testing.expectEqualDeep(testing.second, selection.selected);
    try std.testing.expectEqual(
        testing.model.workspace.find(testing.first.tab_id).?.model.layout.currentRevision(),
        selection.previous_layout_revision,
    );
    try std.testing.expectEqual(
        testing.model.workspace.find(testing.second.tab_id).?.model.layout.currentRevision(),
        selection.selected_layout_revision,
    );
    try std.testing.expectEqual(testing.model.version().workspace, selection.workspace_revision);
    try std.testing.expectEqual(testing.model.version().tabs, selection.tabs_revision);
    try std.testing.expectEqual(testing.model.version().active_tab, selection.active_tab_revision);
    try std.testing.expectEqual(testing.model.version().panes, selection.panes_revision);
    try std.testing.expectEqual(testing.model.version().copy, selection.copy_revision);
    try std.testing.expectEqual(@as(usize, 1), effects.calls);
    try std.testing.expect(effects.observed_commit);
}

test "SelectTabHandler suppresses blocked and ineffective selections" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var snapshots: SnapshotGateCapture = .{ .blocked = true };
    var effects: EffectsCapture = .{ .model = testing.model, .expected = testing.second };
    var handler: SelectTabHandler = .{
        .model = testing.model,
        .snapshots = snapshots.port(),
        .effects = effects.port(),
    };

    try std.testing.expect((try handler.execute(.{ .target = .{ .offset = 1 } })) == null);
    try std.testing.expectEqualDeep(testing.first, testing.model.activeTabLocation().?);
    snapshots.blocked = false;
    try std.testing.expect((try handler.execute(.{ .target = .{ .position = 0 } })) == null);
    try std.testing.expect((try handler.execute(.{ .target = .{ .position = 9 } })) == null);
    try std.testing.expect((try handler.execute(.{ .target = .{ .offset = 2 } })) == null);
    try std.testing.expect((try handler.execute(.{ .target = .{ .tab_id = @enumFromInt(9) } })) == null);
    try std.testing.expectEqual(@as(usize, 0), effects.calls);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());

    testing.model.workspace.deinit();
    try std.testing.expect((try handler.execute(.{ .target = .{ .position = 0 } })) == null);
    try std.testing.expectEqual(@as(usize, 0), effects.calls);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "SelectTabHandler preserves a committed selection after effect failure" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var snapshots: SnapshotGateCapture = .{};
    var effects: EffectsCapture = .{
        .model = testing.model,
        .expected = testing.second,
        .fail = true,
    };
    var handler: SelectTabHandler = .{
        .model = testing.model,
        .snapshots = snapshots.port(),
        .effects = effects.port(),
    };

    try std.testing.expectError(
        error.SelectionSyncFailed,
        handler.execute(.{ .target = .{ .offset = 1 } }),
    );
    try std.testing.expectEqualDeep(testing.second, testing.model.activeTabLocation().?);
    try std.testing.expectEqual(@as(u64, 1), testing.model.version().active_tab);
    try std.testing.expect(effects.observed_commit);
}
