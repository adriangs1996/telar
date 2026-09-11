//! Application use case for changing focus inside one client's active tab.

const FocusPaneTestingModel = @import("FocusPaneTestingModel.zig");
const std = @import("std");
const FocusPaneEffectsCapture = @import("FocusPaneEffectsCapture.zig");
const FocusPaneHandler = @import("FocusPaneHandler.zig");
const VersionType = @import("../../model/Version.zig");

test "FocusPaneHandler commits before delivering active-pane resources" {
    var testing = try FocusPaneTestingModel.init();
    defer testing.deinit();
    try std.testing.expect(testing.model.workspace.active().?.model.toggleFullscreen());
    var effects: FocusPaneEffectsCapture = .{ .model = testing.model, .expected = testing.first };
    var handler: FocusPaneHandler = .{
        .model = testing.model,
        .effects = effects.port(),
    };

    const focus = (try handler.execute(.{
        .target = .{ .direction = .left },
        .area = testing.area,
    })).?;

    try std.testing.expectEqual(testing.second, focus.previous);
    try std.testing.expectEqual(testing.first, focus.focused);
    try std.testing.expect(focus.geometry_changed);
    try std.testing.expectEqual(@as(u64, 1), focus.panes_revision);
    try std.testing.expectEqualDeep(testing.area, effects.area.?);
    try std.testing.expectEqual(@as(usize, 1), effects.calls);
    try std.testing.expect(effects.observed_commit);
}

test "FocusPaneHandler suppresses repeated missing and directionless targets" {
    var testing = try FocusPaneTestingModel.init();
    defer testing.deinit();
    var effects: FocusPaneEffectsCapture = .{ .model = testing.model, .expected = testing.second };
    var handler: FocusPaneHandler = .{
        .model = testing.model,
        .effects = effects.port(),
    };

    try std.testing.expect((try handler.execute(.{
        .target = .{ .pane_id = testing.second },
        .area = testing.area,
    })) == null);
    try std.testing.expect((try handler.execute(.{
        .target = .{ .pane_id = @enumFromInt(9) },
        .area = testing.area,
    })) == null);
    try std.testing.expect((try handler.execute(.{
        .target = .{ .direction = .right },
        .area = testing.area,
    })) == null);

    testing.model.workspace.deinit();
    try std.testing.expect((try handler.execute(.{
        .target = .{ .pane_id = testing.first },
        .area = testing.area,
    })) == null);
    try std.testing.expectEqual(@as(usize, 0), effects.calls);
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "FocusPaneHandler preserves committed focus after effect failure" {
    var testing = try FocusPaneTestingModel.init();
    defer testing.deinit();
    var effects: FocusPaneEffectsCapture = .{
        .model = testing.model,
        .expected = testing.first,
        .fail = true,
    };
    var handler: FocusPaneHandler = .{
        .model = testing.model,
        .effects = effects.port(),
    };

    try std.testing.expectError(error.FocusSyncFailed, handler.execute(.{
        .target = .{ .pane_id = testing.first },
        .area = testing.area,
    }));

    try std.testing.expectEqual(testing.first, testing.model.workspace.activeConst().?.model.layout.focused().?);
    try std.testing.expectEqual(@as(u64, 1), testing.model.version().panes);
    try std.testing.expect(effects.observed_commit);
}
