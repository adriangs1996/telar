//! Application use case for resizing the focused pane in one client's layout.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../root.zig").model;

pub const schema = core.schema;
pub const ui = core.ui;

pub const ResizePane = client_model.ResizePaneRequest;

pub const ResizeEffects = @import("ResizeEffects.zig");

pub const ResizePaneHandler = @import("ResizePaneHandler.zig");

const TestingModel = @import("ResizePaneTestingModel.zig");

const EffectsCapture = @import("ResizePaneEffectsCapture.zig");

test "ResizePaneHandler commits before delivering runtime geometry" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const width_before = testing.model.workspace.active().?.model.contentSize(testing.first, testing.area).?.cols;
    var effects: EffectsCapture = .{
        .model = testing.model,
        .expected_focused = testing.first,
        .width_before = width_before,
    };
    var handler: ResizePaneHandler = .{
        .model = testing.model,
        .effects = effects.port(),
    };

    const resize = (try handler.execute(.{ .direction = .right, .area = testing.area })).?;

    try std.testing.expectEqualDeep(testing.location, resize.location);
    try std.testing.expectEqual(testing.first, resize.focused);
    try std.testing.expectEqualDeep(testing.area, resize.area);
    try std.testing.expectEqualDeep(resize, effects.resize.?);
    try std.testing.expectEqual(@as(usize, 1), effects.calls);
    try std.testing.expect(effects.observed_commit);
}

test "ResizePaneHandler suppresses absent layouts and directions without an edge" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const width_before = testing.model.workspace.active().?.model.contentSize(testing.first, testing.area).?.cols;
    var effects: EffectsCapture = .{
        .model = testing.model,
        .expected_focused = testing.first,
        .width_before = width_before,
    };
    var handler: ResizePaneHandler = .{
        .model = testing.model,
        .effects = effects.port(),
    };

    try std.testing.expect((try handler.execute(.{ .direction = .up, .area = testing.area })) == null);
    testing.model.workspace.deinit();
    try std.testing.expect((try handler.execute(.{ .direction = .right, .area = testing.area })) == null);

    try std.testing.expectEqual(@as(usize, 0), effects.calls);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "ResizePaneHandler preserves the committed layout after effect failure" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const width_before = testing.model.workspace.active().?.model.contentSize(testing.first, testing.area).?.cols;
    var effects: EffectsCapture = .{
        .model = testing.model,
        .expected_focused = testing.first,
        .width_before = width_before,
        .fail = true,
    };
    var handler: ResizePaneHandler = .{
        .model = testing.model,
        .effects = effects.port(),
    };

    try std.testing.expectError(error.ResizeSyncFailed, handler.execute(.{
        .direction = .right,
        .area = testing.area,
    }));

    try std.testing.expect(testing.model.workspace.active().?.model.contentSize(testing.first, testing.area).?.cols > width_before);
    try std.testing.expectEqual(@as(u64, 1), testing.model.version().panes);
    try std.testing.expect(effects.observed_commit);
}
