//! Application use case for committing one resolved host resize.

const ModelType = @import("../../model/Model.zig");
const std = @import("std");
const HostResizeEffectsCapture = @import("HostResizeEffectsCapture.zig");
const ResizeHostHandler = @import("ResizeHostHandler.zig");
const TerminalSizeType = @import("telar-core").TerminalSize;
const VersionType = @import("../../model/Version.zig");

test "ResizeHostHandler commits before synchronizing client resources" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: HostResizeEffectsCapture = .{ .model = &model };
    var handler: ResizeHostHandler = .{
        .model = &model,
        .effects = capture.port(),
    };
    const size: TerminalSizeType = .{
        .cols = 100,
        .rows = 30,
        .cell_width_px = 10,
        .cell_height_px = 20,
    };
    var capabilities = model.hostCapabilities();
    capabilities.window_width_px = 1000;
    capabilities.window_height_px = 600;

    const commit = (try handler.execute(.{
        .capabilities = capabilities,
        .size = size,
    })).?;

    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualDeep(commit, capture.commit.?);
}

test "ResizeHostHandler suppresses repeated and invalid geometry" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: HostResizeEffectsCapture = .{ .model = &model };
    var handler: ResizeHostHandler = .{
        .model = &model,
        .effects = capture.port(),
    };

    try std.testing.expect((try handler.execute(.{
        .capabilities = model.hostCapabilities(),
        .size = model.hostSize(),
    })) == null);
    try std.testing.expectError(error.InvalidTerminalSize, handler.execute(.{
        .capabilities = model.hostCapabilities(),
        .size = .{ .cols = 80, .rows = 0 },
    }));
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expectEqualDeep(VersionType{}, model.version());
}

test "ResizeHostHandler retains the model commit after effect failure" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: HostResizeEffectsCapture = .{
        .model = &model,
        .fail = true,
    };
    var handler: ResizeHostHandler = .{
        .model = &model,
        .effects = capture.port(),
    };
    const size: TerminalSizeType = .{
        .cols = 100,
        .rows = 30,
        .cell_width_px = 10,
        .cell_height_px = 20,
    };
    var capabilities = model.hostCapabilities();
    capabilities.window_width_px = 1000;
    capabilities.window_height_px = 600;

    try std.testing.expectError(error.HostResizeEffectsFailed, handler.execute(.{
        .capabilities = capabilities,
        .size = size,
    }));

    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqualDeep(size, model.hostSize());
    try std.testing.expectEqual(@as(u32, 1000), model.hostCapabilities().window_width_px);
    try std.testing.expectEqual(VersionType{
        .host = 1,
        .host_capabilities = 1,
    }, model.version());
}
