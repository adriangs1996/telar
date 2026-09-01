//! Application policy for delivering disposable host resources after one
//! committed host update.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../model/root.zig");

const schema = core.schema;

pub const SidebarConfiguration = struct {
    capabilities: client_model.HostCapabilities,
    size: schema.TerminalSize,
};

pub const Effects = struct {
    context: *anyopaque,
    sync_graphics_fallbacks: *const fn (*anyopaque) void,
    configure_sidebar: *const fn (*anyopaque, SidebarConfiguration) anyerror!void,
    invalidate_graphics_placements: *const fn (*anyopaque) void,
    resize_presenter: *const fn (*anyopaque, schema.TerminalSize) anyerror!void,
    resize_view: *const fn (*anyopaque, schema.TerminalSize) anyerror!void,
    sync_pane_geometry: *const fn (*anyopaque) anyerror!void,
    apply_appearance: *const fn (*anyopaque, client_model.HostAppearance) anyerror!void,
};

pub const DeliverHostResourcesHandler = struct {
    model: *const client_model.Model,
    effects: Effects,

    /// Delivers the resources implied by one current `HostCommit` in graphics,
    /// presentation and pane-geometry order.
    ///
    /// ```zig
    /// try handler.execute(commit);
    /// ```
    pub fn execute(handler: *DeliverHostResourcesHandler, commit: client_model.HostCommit) !void {
        try handler.validate(commit);

        if (commit.capabilities) |capabilities| {
            if (capabilities.previous.appearance != capabilities.current.appearance) {
                try handler.effects.apply_appearance(handler.effects.context, capabilities.current.appearance);
            }

            const graphics_changed = capabilities.previous.kitty_graphics !=
                capabilities.current.kitty_graphics;
            if (graphics_changed) {
                handler.effects.sync_graphics_fallbacks(handler.effects.context);
                try handler.effects.configure_sidebar(handler.effects.context, .{
                    .capabilities = capabilities.current,
                    .size = handler.model.hostSize(),
                });
                handler.effects.invalidate_graphics_placements(handler.effects.context);
            }
        }

        if (commit.resize) |resize| {
            if (resize.grid_changed) {
                try handler.effects.resize_presenter(handler.effects.context, resize.current);
                try handler.effects.resize_view(handler.effects.context, resize.current);
            }

            if (resize.cell_size_changed) {
                try handler.effects.configure_sidebar(handler.effects.context, .{
                    .capabilities = handler.model.hostCapabilities(),
                    .size = resize.current,
                });
            }

            handler.effects.invalidate_graphics_placements(handler.effects.context);
            try handler.effects.sync_pane_geometry(handler.effects.context);
        }
    }

    fn validate(handler: *const DeliverHostResourcesHandler, commit: client_model.HostCommit) !void {
        if (commit.capabilities == null and commit.resize == null) {
            return error.EmptyHostCommit;
        }

        const version = handler.model.version();
        if (commit.capabilities) |capabilities| {
            if (!std.meta.eql(handler.model.hostCapabilities(), capabilities.current) or
                version.host_capabilities != capabilities.host_capabilities_revision)
            {
                return error.StaleHostCommit;
            }
        }

        if (commit.resize) |resize| {
            if (!std.meta.eql(handler.model.hostSize(), resize.current) or
                version.host != resize.host_revision)
            {
                return error.StaleHostCommit;
            }
        }
    }
};

const Event = enum {
    graphics_fallbacks,
    sidebar,
    invalidate_placements,
    presenter_resize,
    view_resize,
    pane_geometry,
};

const Failure = enum {
    none,
    sidebar,
    presenter_resize,
    view_resize,
    pane_geometry,
};

const EffectCapture = struct {
    model: *const client_model.Model,
    commit: client_model.HostCommit,
    events: [10]Event = undefined,
    event_count: usize = 0,
    sidebar_configurations: [2]SidebarConfiguration = undefined,
    sidebar_configuration_count: usize = 0,
    committed_state_observed: bool = true,
    failure: Failure = .none,
    appearance: ?client_model.HostAppearance = null,

    fn effects(capture: *EffectCapture) Effects {
        return .{
            .context = capture,
            .sync_graphics_fallbacks = syncGraphicsFallbacks,
            .configure_sidebar = configureSidebar,
            .invalidate_graphics_placements = invalidateGraphicsPlacements,
            .resize_presenter = resizePresenter,
            .resize_view = resizeView,
            .sync_pane_geometry = syncPaneGeometry,
            .apply_appearance = applyAppearance,
        };
    }

    fn applyAppearance(context: *anyopaque, appearance: client_model.HostAppearance) !void {
        const capture: *EffectCapture = @ptrCast(@alignCast(context));
        capture.appearance = appearance;
    }

    fn syncGraphicsFallbacks(context: *anyopaque) void {
        const capture: *EffectCapture = @ptrCast(@alignCast(context));
        capture.append(.graphics_fallbacks);
    }

    fn configureSidebar(context: *anyopaque, configuration: SidebarConfiguration) !void {
        const capture: *EffectCapture = @ptrCast(@alignCast(context));
        capture.append(.sidebar);
        capture.sidebar_configurations[capture.sidebar_configuration_count] = configuration;
        capture.sidebar_configuration_count += 1;

        if (capture.failure == .sidebar) {
            return error.SidebarConfigurationFailed;
        }
    }

    fn invalidateGraphicsPlacements(context: *anyopaque) void {
        const capture: *EffectCapture = @ptrCast(@alignCast(context));
        capture.append(.invalidate_placements);
    }

    fn resizePresenter(context: *anyopaque, size: schema.TerminalSize) !void {
        const capture: *EffectCapture = @ptrCast(@alignCast(context));
        capture.append(.presenter_resize);
        const resize = capture.commit.resize.?;
        capture.committed_state_observed = capture.committed_state_observed and
            std.meta.eql(size, resize.current);

        if (capture.failure == .presenter_resize) {
            return error.PresenterResizeFailed;
        }
    }

    fn resizeView(context: *anyopaque, size: schema.TerminalSize) !void {
        const capture: *EffectCapture = @ptrCast(@alignCast(context));
        capture.append(.view_resize);
        const resize = capture.commit.resize.?;
        capture.committed_state_observed = capture.committed_state_observed and
            std.meta.eql(size, resize.current);

        if (capture.failure == .view_resize) {
            return error.ViewResizeFailed;
        }
    }

    fn syncPaneGeometry(context: *anyopaque) !void {
        const capture: *EffectCapture = @ptrCast(@alignCast(context));
        capture.append(.pane_geometry);

        if (capture.failure == .pane_geometry) {
            return error.PaneGeometryFailed;
        }
    }

    fn append(capture: *EffectCapture, event: Event) void {
        capture.observeCommit();
        capture.events[capture.event_count] = event;
        capture.event_count += 1;
    }

    fn observeCommit(capture: *EffectCapture) void {
        const version = capture.model.version();
        if (capture.commit.capabilities) |capabilities| {
            capture.committed_state_observed = capture.committed_state_observed and
                std.meta.eql(capture.model.hostCapabilities(), capabilities.current) and
                version.host_capabilities == capabilities.host_capabilities_revision;
        }

        if (capture.commit.resize) |resize| {
            capture.committed_state_observed = capture.committed_state_observed and
                std.meta.eql(capture.model.hostSize(), resize.current) and
                version.host == resize.host_revision;
        }
    }

    fn eventSlice(capture: *const EffectCapture) []const Event {
        return capture.events[0..capture.event_count];
    }
};

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
    const commit = (try model.observeHostCapability(.{ .kitty_graphics = .supported })).?;
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
    const commit = (try model.observeHostCapability(.{ .mouse_pixels = .supported })).?;
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
    const stale = (try model.observeHostCapability(.{ .kitty_graphics = .supported })).?;
    _ = (try model.observeHostCapability(.{ .kitty_zlib = .supported })).?;
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
    const commit = (try model.observeHostCapability(.{ .kitty_graphics = .supported })).?;
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
