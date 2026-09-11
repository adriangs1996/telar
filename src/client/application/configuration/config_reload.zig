//! Application use case for adopting one client configuration generation.

const std = @import("std");
const bars = @import("../../bars/root.zig");
const client_diagnostic = @import("client_diagnostic.zig");
const client_model = @import("../../root.zig").model;

pub const Command = @import("ConfigReloadCommand.zig");

pub const Effects = @import("ConfigReloadEffects.zig");

pub const ApplyConfigHandler = @import("ApplyConfigHandler.zig");

pub const Event = enum {
    adopt_resources,
    synchronize_bars,
    project_appearance,
    configure_sidebar,
    apply_sidebar,
    invalidate_graphics_placements,
    offer_active_pane_geometry,
};

pub const Failure = enum {
    none,
    synchronize_bars,
    configure_sidebar,
    apply_sidebar,
    pane_geometry,
};

const EffectsCapture = @import("EffectsCapture.zig");

fn installDiagnostic(model: *client_model.Model) !void {
    _ = try model.replaceDiagnostic(client_diagnostic.formatted("previous configuration failed", .{}));
}

test "ApplyConfigHandler owns ordered sidebar adoption after the model commit" {
    var model = client_model.Model.initWithConfiguration(std.testing.allocator, true, 1);
    defer model.deinit();
    try installDiagnostic(&model);
    var capture: EffectsCapture = .{ .model = &model };
    var handler: ApplyConfigHandler = .{
        .model = &model,
        .effects = capture.port(),
    };

    const commit = try handler.execute(.{
        .configuration = .{
            .generation = 2,
            .sidebar_visible = false,
            .pane_gaps = false,
        },
        .theme_locked = false,
    });

    try std.testing.expectEqualSlices(Event, &.{
        .adopt_resources,
        .project_appearance,
        .configure_sidebar,
        .apply_sidebar,
    }, capture.eventSlice());
    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqualDeep(commit, capture.commit.?);
    try std.testing.expect(capture.apply_theme.?);
    try std.testing.expectEqualDeep(commit.sidebar.?, capture.sidebar.?);
    try std.testing.expect(!model.sidebarVisible());
    try std.testing.expect(!model.paneGaps());
    try std.testing.expectEqual(client_model.Version{
        .configuration = 1,
        .diagnostic = 2,
        .panes = 1,
        .chrome = 1,
    }, model.version());
}

test "ApplyConfigHandler orders pane layout delivery and honors a locked theme" {
    var model = client_model.Model.initWithConfiguration(std.testing.allocator, true, 1);
    defer model.deinit();
    var capture: EffectsCapture = .{ .model = &model };
    var handler: ApplyConfigHandler = .{
        .model = &model,
        .effects = capture.port(),
    };

    _ = try handler.execute(.{
        .configuration = .{
            .generation = 2,
            .sidebar_visible = true,
            .pane_gaps = false,
        },
        .theme_locked = true,
    });

    try std.testing.expectEqualSlices(Event, &.{
        .adopt_resources,
        .project_appearance,
        .configure_sidebar,
        .invalidate_graphics_placements,
        .offer_active_pane_geometry,
    }, capture.eventSlice());
    try std.testing.expect(capture.observed_commit);
    try std.testing.expect(!capture.apply_theme.?);
    try std.testing.expect(capture.sidebar == null);
}

test "ApplyConfigHandler rejects stale input before clearing diagnostics or effects" {
    var model = client_model.Model.initWithConfiguration(std.testing.allocator, true, 2);
    defer model.deinit();
    try installDiagnostic(&model);
    var capture: EffectsCapture = .{ .model = &model };
    var handler: ApplyConfigHandler = .{
        .model = &model,
        .effects = capture.port(),
    };

    try std.testing.expectError(error.StaleConfiguration, handler.execute(.{
        .configuration = .{
            .generation = 2,
            .sidebar_visible = false,
            .pane_gaps = false,
        },
        .theme_locked = false,
    }));

    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
    try std.testing.expectEqualStrings("previous configuration failed", model.diagnostic().?);
    try std.testing.expectEqual(client_model.Version{ .diagnostic = 1 }, model.version());
}

test "ApplyConfigHandler rearms changed bars after their generation is adopted" {
    const configuration: bars.Configuration = .{
        .bottom = .{
            .{ .dynamic = .{ .callback = .{ .generation = 2, .id = 0 }, .interval_ns = std.time.ns_per_s } },
            .empty,
            .tabs,
        },
    };
    var model = client_model.Model.initWithConfiguration(std.testing.allocator, true, 1);
    defer model.deinit();
    var capture: EffectsCapture = .{ .model = &model };
    var handler: ApplyConfigHandler = .{ .model = &model, .effects = capture.port() };

    const commit = try handler.execute(.{
        .configuration = .{
            .generation = 2,
            .sidebar_visible = true,
            .pane_gaps = true,
            .bars = configuration.presentation(),
        },
        .theme_locked = false,
    });

    try std.testing.expectEqualSlices(Event, &.{
        .adopt_resources,
        .synchronize_bars,
        .project_appearance,
        .configure_sidebar,
    }, capture.eventSlice());
    try std.testing.expect(commit.bars_changed);
    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(@as(u64, 1), model.version().bars);
}

test "ApplyConfigHandler retains adopted bars when rearming fails" {
    const configuration: bars.Configuration = .{
        .bottom = .{
            .{ .dynamic = .{ .callback = .{ .generation = 2, .id = 0 }, .interval_ns = std.time.ns_per_s } },
            .empty,
            .tabs,
        },
    };
    var model = client_model.Model.initWithConfiguration(std.testing.allocator, true, 1);
    defer model.deinit();
    var capture: EffectsCapture = .{ .model = &model, .failure = .synchronize_bars };
    var handler: ApplyConfigHandler = .{ .model = &model, .effects = capture.port() };

    try std.testing.expectError(error.BarSynchronizationFailed, handler.execute(.{
        .configuration = .{
            .generation = 2,
            .sidebar_visible = true,
            .pane_gaps = true,
            .bars = configuration.presentation(),
        },
        .theme_locked = false,
    }));

    try std.testing.expectEqualSlices(Event, &.{ .adopt_resources, .synchronize_bars }, capture.eventSlice());
    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(@as(u64, 2), model.configurationGeneration());
    try std.testing.expectEqual(@as(u64, 1), model.version().bars);
}

test "ApplyConfigHandler preserves every applied stage after delivery failures" {
    const Scenario = struct {
        failure: Failure,
        sidebar_changed: bool,
        expected_error: anyerror,
        expected_events: []const Event,
    };
    const scenarios = [_]Scenario{
        .{
            .failure = .configure_sidebar,
            .sidebar_changed = true,
            .expected_error = error.SidebarConfigurationFailed,
            .expected_events = &.{ .adopt_resources, .project_appearance, .configure_sidebar },
        },
        .{
            .failure = .apply_sidebar,
            .sidebar_changed = true,
            .expected_error = error.SidebarProjectionFailed,
            .expected_events = &.{ .adopt_resources, .project_appearance, .configure_sidebar, .apply_sidebar },
        },
        .{
            .failure = .pane_geometry,
            .sidebar_changed = false,
            .expected_error = error.PaneGeometryFailed,
            .expected_events = &.{
                .adopt_resources,
                .project_appearance,
                .configure_sidebar,
                .invalidate_graphics_placements,
                .offer_active_pane_geometry,
            },
        },
    };

    for (scenarios) |scenario| {
        var model = client_model.Model.initWithConfiguration(std.testing.allocator, true, 1);
        defer model.deinit();
        try installDiagnostic(&model);
        var capture: EffectsCapture = .{
            .model = &model,
            .failure = scenario.failure,
        };
        var handler: ApplyConfigHandler = .{
            .model = &model,
            .effects = capture.port(),
        };

        try std.testing.expectError(scenario.expected_error, handler.execute(.{
            .configuration = .{
                .generation = 2,
                .sidebar_visible = !scenario.sidebar_changed,
                .pane_gaps = false,
            },
            .theme_locked = false,
        }));

        try std.testing.expectEqualSlices(Event, scenario.expected_events, capture.eventSlice());
        try std.testing.expect(capture.observed_commit);
        try std.testing.expectEqual(@as(u64, 2), model.configurationGeneration());
        try std.testing.expect(model.diagnostic() == null);
        try std.testing.expect(!model.paneGaps());
    }
}
