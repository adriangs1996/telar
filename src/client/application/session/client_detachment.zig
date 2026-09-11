//! Application policy for detaching every tab owned by one client.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../root.zig").model;

pub const schema = core.schema;

pub const Effects = @import("ClientDetachmentEffects.zig");

pub const DetachClientHandler = @import("DetachClientHandler.zig");

const Capture = @import("Capture.zig");

const TestingModel = @import("TestingModel.zig");

test "DetachClientHandler delivers every captured tab in stable order" {
    var testing = try TestingModel.init(3);
    defer testing.deinit();
    var capture: Capture = .{};
    var handler: DetachClientHandler = .{
        .model = testing.model,
        .effects = capture.effects(),
    };
    const version = testing.model.version();

    try handler.execute();

    try std.testing.expectEqualSlices(schema.TabLocation, &testing.locations, capture.slice());
    try std.testing.expectEqualDeep(version, testing.model.version());
}

test "DetachClientHandler accepts an empty client without effects" {
    var testing = try TestingModel.init(0);
    defer testing.deinit();
    var capture: Capture = .{};
    var handler: DetachClientHandler = .{
        .model = testing.model,
        .effects = capture.effects(),
    };

    try handler.execute();

    try std.testing.expectEqual(@as(usize, 0), capture.location_count);
}

test "DetachClientHandler stops after the first failed tab retirement" {
    var testing = try TestingModel.init(3);
    defer testing.deinit();
    var capture: Capture = .{ .fail_at = 2 };
    var handler: DetachClientHandler = .{
        .model = testing.model,
        .effects = capture.effects(),
    };

    try std.testing.expectError(error.DetachmentFailed, handler.execute());

    try std.testing.expectEqualSlices(schema.TabLocation, testing.locations[0..2], capture.slice());
}
