//! Application use case for adopting one client configuration generation.

const std = @import("std");
const bars = @import("../../../bars/root.zig");
const client_diagnostic = @import("client_diagnostic.zig");
const client_model = @import("../../model/root.zig");

pub const Command = struct {
    configuration: client_model.ConfigurationInput,
    theme_locked: bool,
};

pub const Effects = struct {
    context: *anyopaque,
    adopt_resources: *const fn (*anyopaque, client_model.ConfigurationCommit) void,
    synchronize_bars: *const fn (*anyopaque) anyerror!void,
    project_appearance: *const fn (*anyopaque, bool) void,
    configure_sidebar: *const fn (*anyopaque) anyerror!void,
    apply_sidebar: *const fn (*anyopaque, client_model.SidebarLayout) anyerror!void,
    invalidate_graphics_placements: *const fn (*anyopaque) void,
    offer_active_pane_geometry: *const fn (*anyopaque) anyerror!void,
};

pub const ApplyConfigHandler = struct {
    model: *client_model.Model,
    effects: Effects,

    /// Commits semantic configuration, clears an obsolete diagnostic and
    /// delivers concrete resources in deterministic application order.
    ///
    /// ```zig
    /// const commit = try handler.execute(command);
    /// ```
    pub fn execute(handler: *ApplyConfigHandler, command: Command) !client_model.ConfigurationCommit {
        const commit = try handler.model.applyConfiguration(command.configuration);
        var diagnostic_handler: client_diagnostic.ClientDiagnosticHandler = .{ .model = handler.model };
        _ = diagnostic_handler.clear();

        handler.effects.adopt_resources(handler.effects.context, commit);
        if (commit.bars_changed) {
            try handler.effects.synchronize_bars(handler.effects.context);
        }
        handler.effects.project_appearance(handler.effects.context, !command.theme_locked);
        try handler.effects.configure_sidebar(handler.effects.context);

        if (commit.sidebar) |sidebar| {
            try handler.effects.apply_sidebar(handler.effects.context, sidebar);
        } else if (commit.pane_gaps_changed) {
            handler.effects.invalidate_graphics_placements(handler.effects.context);
            try handler.effects.offer_active_pane_geometry(handler.effects.context);
        }

        return commit;
    }
};

const Event = enum {
    adopt_resources,
    synchronize_bars,
    project_appearance,
    configure_sidebar,
    apply_sidebar,
    invalidate_graphics_placements,
    offer_active_pane_geometry,
};

const Failure = enum {
    none,
    synchronize_bars,
    configure_sidebar,
    apply_sidebar,
    pane_geometry,
};

const EffectsCapture = struct {
    model: *const client_model.Model,
    events: [7]Event = undefined,
    event_count: usize = 0,
    commit: ?client_model.ConfigurationCommit = null,
    apply_theme: ?bool = null,
    sidebar: ?client_model.SidebarLayout = null,
    observed_commit: bool = true,
    failure: Failure = .none,

    fn port(capture: *EffectsCapture) Effects {
        return .{
            .context = capture,
            .adopt_resources = adoptResources,
            .synchronize_bars = synchronizeBars,
            .project_appearance = projectAppearance,
            .configure_sidebar = configureSidebar,
            .apply_sidebar = applySidebar,
            .invalidate_graphics_placements = invalidateGraphicsPlacements,
            .offer_active_pane_geometry = offerActivePaneGeometry,
        };
    }

    fn adoptResources(context: *anyopaque, commit: client_model.ConfigurationCommit) void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.commit = commit;
        capture.record(.adopt_resources);
        capture.observeCommit();
    }

    fn projectAppearance(context: *anyopaque, apply_theme: bool) void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.apply_theme = apply_theme;
        capture.record(.project_appearance);
        capture.observeCommit();
    }

    fn synchronizeBars(context: *anyopaque) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.record(.synchronize_bars);
        capture.observeCommit();

        if (capture.failure == .synchronize_bars) {
            return error.BarSynchronizationFailed;
        }
    }

    fn configureSidebar(context: *anyopaque) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.record(.configure_sidebar);
        capture.observeCommit();

        if (capture.failure == .configure_sidebar) {
            return error.SidebarConfigurationFailed;
        }
    }

    fn applySidebar(context: *anyopaque, sidebar: client_model.SidebarLayout) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.sidebar = sidebar;
        capture.record(.apply_sidebar);
        capture.observeCommit();

        if (capture.failure == .apply_sidebar) {
            return error.SidebarProjectionFailed;
        }
    }

    fn invalidateGraphicsPlacements(context: *anyopaque) void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.record(.invalidate_graphics_placements);
        capture.observeCommit();
    }

    fn offerActivePaneGeometry(context: *anyopaque) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.record(.offer_active_pane_geometry);
        capture.observeCommit();

        if (capture.failure == .pane_geometry) {
            return error.PaneGeometryFailed;
        }
    }

    fn observeCommit(capture: *EffectsCapture) void {
        const commit = capture.commit orelse {
            capture.observed_commit = false;
            return;
        };

        capture.observed_commit = capture.observed_commit and
            capture.model.configurationGeneration() == commit.generation and
            capture.model.version().configuration == commit.configuration_revision and
            capture.model.version().panes == commit.panes_revision and
            capture.model.version().bars == commit.bars_revision and
            capture.model.diagnostic() == null;
    }

    fn record(capture: *EffectsCapture, event: Event) void {
        capture.events[capture.event_count] = event;
        capture.event_count += 1;
    }

    fn eventSlice(capture: *const EffectsCapture) []const Event {
        return capture.events[0..capture.event_count];
    }
};

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
