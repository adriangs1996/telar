//! Application use case for toggling one client's focused pane fullscreen.

const TogglePaneFullscreenTestingModel = @import("TogglePaneFullscreenTestingModel.zig");
const TogglePaneFullscreenEffectsCapture = @import("TogglePaneFullscreenEffectsCapture.zig");
const TogglePaneFullscreenHandler = @import("TogglePaneFullscreenHandler.zig");
const std = @import("std");
const VersionType = @import("../../model/Version.zig");

test "TogglePaneFullscreenHandler commits before delivering geometry" {
    var testing = try TogglePaneFullscreenTestingModel.init();
    defer testing.deinit();
    var effects: TogglePaneFullscreenEffectsCapture = .{
        .model = testing.model,
        .expected_focused = testing.first,
    };
    var handler: TogglePaneFullscreenHandler = .{
        .model = testing.model,
        .effects = effects.port(),
    };

    const change = (try handler.execute(.{ .area = testing.area })).?;

    try std.testing.expectEqualDeep(testing.location, change.location);
    try std.testing.expectEqual(testing.first, change.focused);
    try std.testing.expectEqualDeep(testing.area, change.area);
    try std.testing.expect(change.fullscreen);
    try std.testing.expectEqualDeep(change, effects.change.?);
    try std.testing.expectEqual(@as(usize, 1), effects.calls);
    try std.testing.expect(effects.observed_commit);
}

test "TogglePaneFullscreenHandler accepts a single pane and suppresses absent layouts" {
    var testing = try TogglePaneFullscreenTestingModel.init();
    defer testing.deinit();
    var effects: TogglePaneFullscreenEffectsCapture = .{
        .model = testing.model,
        .expected_focused = testing.first,
    };
    var handler: TogglePaneFullscreenHandler = .{
        .model = testing.model,
        .effects = effects.port(),
    };

    try std.testing.expect(testing.model.workspace.active().?.model.removePane(testing.second));
    const change = (try handler.execute(.{ .area = testing.area })).?;
    try std.testing.expect(change.fullscreen);
    try std.testing.expectEqual(testing.first, change.focused);
    try std.testing.expect(effects.observed_commit);
    testing.model.workspace.deinit();
    try std.testing.expect((try handler.execute(.{ .area = testing.area })) == null);

    try std.testing.expectEqual(@as(usize, 1), effects.calls);
    try std.testing.expectEqualDeep(VersionType{ .panes = 1 }, testing.model.version());
}

test "TogglePaneFullscreenHandler preserves the commit after effect failure" {
    var testing = try TogglePaneFullscreenTestingModel.init();
    defer testing.deinit();
    var effects: TogglePaneFullscreenEffectsCapture = .{
        .model = testing.model,
        .expected_focused = testing.first,
        .fail = true,
    };
    var handler: TogglePaneFullscreenHandler = .{
        .model = testing.model,
        .effects = effects.port(),
    };

    try std.testing.expectError(error.FullscreenSyncFailed, handler.execute(.{ .area = testing.area }));

    try std.testing.expect(testing.model.workspace.activeConst().?.model.layout.isFullscreen());
    try std.testing.expectEqual(@as(u64, 1), testing.model.version().panes);
    try std.testing.expect(effects.observed_commit);
}
