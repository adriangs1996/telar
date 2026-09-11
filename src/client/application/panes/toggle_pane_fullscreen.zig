//! Application use case for toggling one client's focused pane fullscreen.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../root.zig").model;

pub const schema = core.schema;
pub const ui = core.ui;

pub const TogglePaneFullscreen = client_model.TogglePaneFullscreenRequest;

pub const FullscreenEffects = @import("FullscreenEffects.zig");

pub const TogglePaneFullscreenHandler = @import("TogglePaneFullscreenHandler.zig");

const TestingModel = @import("TogglePaneFullscreenTestingModel.zig");

const EffectsCapture = @import("TogglePaneFullscreenEffectsCapture.zig");

test "TogglePaneFullscreenHandler commits before delivering geometry" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var effects: EffectsCapture = .{
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
    var testing = try TestingModel.init();
    defer testing.deinit();
    var effects: EffectsCapture = .{
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
    try std.testing.expectEqualDeep(client_model.Version{ .panes = 1 }, testing.model.version());
}

test "TogglePaneFullscreenHandler preserves the commit after effect failure" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var effects: EffectsCapture = .{
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
