//! Application use case for resizing the focused pane in one client's layout.

const ResizePaneTestingModel = @import("ResizePaneTestingModel.zig");
const ResizePaneEffectsCapture = @import("ResizePaneEffectsCapture.zig");
const ResizePaneHandler = @import("ResizePaneHandler.zig");
const std = @import("std");
const VersionType = @import("../../model/Version.zig");

test "ResizePaneHandler commits before delivering runtime geometry" {
    var testing = try ResizePaneTestingModel.init();
    defer testing.deinit();
    const width_before = testing.model.workspace.active().?.model.contentSize(testing.first, testing.area).?.cols;
    var effects: ResizePaneEffectsCapture = .{
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
    var testing = try ResizePaneTestingModel.init();
    defer testing.deinit();
    const width_before = testing.model.workspace.active().?.model.contentSize(testing.first, testing.area).?.cols;
    var effects: ResizePaneEffectsCapture = .{
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
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "ResizePaneHandler preserves the committed layout after effect failure" {
    var testing = try ResizePaneTestingModel.init();
    defer testing.deinit();
    const width_before = testing.model.workspace.active().?.model.contentSize(testing.first, testing.area).?.cols;
    var effects: ResizePaneEffectsCapture = .{
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
