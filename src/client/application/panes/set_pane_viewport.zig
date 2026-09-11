//! Application use case for changing one pane's client-owned viewport.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../root.zig").model;

pub const schema = core.schema;

pub const SetPaneViewport = client_model.PaneViewportCommand;

pub const PaneViewportEffects = @import("PaneViewportEffects.zig");

pub const SetPaneViewportHandler = @import("SetPaneViewportHandler.zig");

const TestingModel = @import("SetPaneViewportTestingModel.zig");

const EffectsCapture = @import("SetPaneViewportEffectsCapture.zig");

test "SetPaneViewportHandler commits before synchronizing client resources" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{ .model = testing.model };
    var handler: SetPaneViewportHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    const change = (try handler.execute(.{
        .pane_id = testing.pane_id,
        .target = .{ .relative = -4 },
    })).?;

    try std.testing.expectEqual(@as(u32, 6), change.offset);
    try std.testing.expect(!change.at_bottom);
    try std.testing.expectEqual(@as(u64, 1), change.viewport_revision);
    try std.testing.expectEqualDeep(change, capture.change.?);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.observed_commit);
}

test "SetPaneViewportHandler suppresses repeated and unavailable targets" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{ .model = testing.model };
    var handler: SetPaneViewportHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    try std.testing.expect((try handler.execute(.{
        .pane_id = testing.pane_id,
        .target = .{ .absolute = 10 },
    })) == null);
    try std.testing.expect((try handler.execute(.{
        .pane_id = @enumFromInt(9),
        .target = .bottom,
    })) == null);

    testing.model.workspace.findPane(testing.pane_id).?.attached = false;
    try std.testing.expect((try handler.execute(.{
        .pane_id = testing.pane_id,
        .target = .bottom,
    })) == null);

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "SetPaneViewportHandler preserves the committed viewport after effect failure" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{ .model = testing.model, .fail = true };
    var handler: SetPaneViewportHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    try std.testing.expectError(error.ViewportSyncFailed, handler.execute(.{
        .pane_id = testing.pane_id,
        .target = .bottom,
    }));

    try std.testing.expectEqual(@as(u32, 15), testing.model.workspace.findPane(testing.pane_id).?.scroll.offset);
    try std.testing.expectEqual(client_model.Version{ .viewport = 1 }, testing.model.version());
    try std.testing.expect(capture.observed_commit);
}
