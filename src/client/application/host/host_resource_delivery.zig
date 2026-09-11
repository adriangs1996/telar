//! Application policy for delivering disposable host resources after one
//! committed host update.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../root.zig").model;

pub const schema = core.schema;

pub const SidebarConfiguration = @import("SidebarConfiguration.zig");

pub const Effects = @import("HostResourceDeliveryEffects.zig");

pub const DeliverHostResourcesHandler = @import("DeliverHostResourcesHandler.zig");

pub const Event = enum {
    graphics_fallbacks,
    sidebar,
    invalidate_placements,
    presenter_resize,
    view_resize,
    pane_geometry,
};

pub const Failure = enum {
    none,
    sidebar,
    presenter_resize,
    view_resize,
    pane_geometry,
};

const EffectCapture = @import("EffectCapture.zig");

fn resizeCommit(model: *client_model.Model) !client_model.HostCommit {
    var capabilities = model.hostCapabilities();
    capabilities.window_width_px = 1000;
    capabilities.window_height_px = 600;

    return (try model.reconcileHost(.{
        .capabilities = capabilities,
        .size = .{
            .cols = 100,
            .rows = 30,
            .cell_width_px = 10,
            .cell_height_px = 20,
        },
    })).?;
}

test "DeliverHostResourcesHandler orders graphics capability resources" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const commit = (try model.observeHostCapability(.{ .images = .supported })).?;
    var capture: EffectCapture = .{ .model = &model, .commit = commit };
    var handler: DeliverHostResourcesHandler = .{
        .model = &model,
        .effects = capture.effects(),
    };

    try handler.execute(commit);

    try std.testing.expectEqualSlices(Event, &.{
        .graphics_fallbacks,
        .sidebar,
        .invalidate_placements,
    }, capture.eventSlice());
    try std.testing.expectEqual(@as(usize, 1), capture.sidebar_configuration_count);
    try std.testing.expectEqualDeep(SidebarConfiguration{
        .capabilities = model.hostCapabilities(),
        .size = model.hostSize(),
    }, capture.sidebar_configurations[0]);
    try std.testing.expect(capture.committed_state_observed);
}

test "DeliverHostResourcesHandler orders grid and cell-size resources" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const commit = try resizeCommit(&model);
    var capture: EffectCapture = .{ .model = &model, .commit = commit };
    var handler: DeliverHostResourcesHandler = .{
        .model = &model,
        .effects = capture.effects(),
    };

    try handler.execute(commit);

    try std.testing.expectEqualSlices(Event, &.{
        .presenter_resize,
        .view_resize,
        .sidebar,
        .invalidate_placements,
        .pane_geometry,
    }, capture.eventSlice());
    try std.testing.expectEqualDeep(SidebarConfiguration{
        .capabilities = model.hostCapabilities(),
        .size = model.hostSize(),
    }, capture.sidebar_configurations[0]);
    try std.testing.expect(capture.committed_state_observed);
}

test "DeliverHostResourcesHandler selects grid and cell-size branches independently" {
    {
        var model = client_model.Model.init(std.testing.allocator, true);
        defer model.deinit();
        const commit = (try model.reconcileHost(.{
            .capabilities = model.hostCapabilities(),
            .size = .{ .cols = 100, .rows = 30 },
        })).?;
        var capture: EffectCapture = .{ .model = &model, .commit = commit };
        var handler: DeliverHostResourcesHandler = .{
            .model = &model,
            .effects = capture.effects(),
        };

        try handler.execute(commit);

        try std.testing.expectEqualSlices(Event, &.{
            .presenter_resize,
            .view_resize,
            .invalidate_placements,
            .pane_geometry,
        }, capture.eventSlice());
        try std.testing.expectEqual(@as(usize, 0), capture.sidebar_configuration_count);
    }

    {
        var model = client_model.Model.init(std.testing.allocator, true);
        defer model.deinit();
        const commit = (try model.observeHostCapability(.{ .cell_pixels = .{
            .width = 10,
            .height = 20,
        } })).?;
        var capture: EffectCapture = .{ .model = &model, .commit = commit };
        var handler: DeliverHostResourcesHandler = .{
            .model = &model,
            .effects = capture.effects(),
        };

        try handler.execute(commit);

        try std.testing.expectEqualSlices(Event, &.{
            .sidebar,
            .invalidate_placements,
            .pane_geometry,
        }, capture.eventSlice());
        try std.testing.expectEqual(@as(usize, 1), capture.sidebar_configuration_count);
    }
}

test "DeliverHostResourcesHandler skips resources for nonvisual capability changes" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const commit = (try model.observeHostCapability(.{ .pointer_pixels = .supported })).?;
    var capture: EffectCapture = .{ .model = &model, .commit = commit };
    var handler: DeliverHostResourcesHandler = .{
        .model = &model,
        .effects = capture.effects(),
    };

    try handler.execute(commit);

    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "DeliverHostResourcesHandler rejects empty and stale commits before effects" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const stale = (try model.observeHostCapability(.{ .images = .supported })).?;
    _ = (try model.observeHostCapability(.{ .pointer_pixels = .supported })).?;
    var capture: EffectCapture = .{ .model = &model, .commit = stale };
    var handler: DeliverHostResourcesHandler = .{
        .model = &model,
        .effects = capture.effects(),
    };

    try std.testing.expectError(error.EmptyHostCommit, handler.execute(.{
        .capabilities = null,
        .resize = null,
    }));
    try std.testing.expectError(error.StaleHostCommit, handler.execute(stale));
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "DeliverHostResourcesHandler stops resize delivery at each failed effect" {
    const failures = [_]Failure{
        .presenter_resize,
        .view_resize,
        .sidebar,
        .pane_geometry,
    };
    const expected = [_][]const Event{
        &.{.presenter_resize},
        &.{ .presenter_resize, .view_resize },
        &.{ .presenter_resize, .view_resize, .sidebar },
        &.{ .presenter_resize, .view_resize, .sidebar, .invalidate_placements, .pane_geometry },
    };
    const errors = [_]anyerror{
        error.PresenterResizeFailed,
        error.ViewResizeFailed,
        error.SidebarConfigurationFailed,
        error.PaneGeometryFailed,
    };

    for (failures, expected, errors) |failure, events, expected_error| {
        var model = client_model.Model.init(std.testing.allocator, true);
        defer model.deinit();
        const commit = try resizeCommit(&model);
        var capture: EffectCapture = .{
            .model = &model,
            .commit = commit,
            .failure = failure,
        };
        var handler: DeliverHostResourcesHandler = .{
            .model = &model,
            .effects = capture.effects(),
        };

        try std.testing.expectError(expected_error, handler.execute(commit));
        try std.testing.expectEqualSlices(Event, events, capture.eventSlice());
        try std.testing.expect(capture.committed_state_observed);
        try std.testing.expectEqualDeep(commit.resize.?.current, model.hostSize());
    }
}

test "DeliverHostResourcesHandler stops graphics delivery before invalidation" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const commit = (try model.observeHostCapability(.{ .images = .supported })).?;
    var capture: EffectCapture = .{
        .model = &model,
        .commit = commit,
        .failure = .sidebar,
    };
    var handler: DeliverHostResourcesHandler = .{
        .model = &model,
        .effects = capture.effects(),
    };

    try std.testing.expectError(error.SidebarConfigurationFailed, handler.execute(commit));
    try std.testing.expectEqualSlices(Event, &.{ .graphics_fallbacks, .sidebar }, capture.eventSlice());
    try std.testing.expect(capture.committed_state_observed);
    try std.testing.expectEqualDeep(commit.capabilities.?.current, model.hostCapabilities());
}
