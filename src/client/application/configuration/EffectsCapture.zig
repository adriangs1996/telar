const EffectsCapture = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("config_reload.zig");
const Effects = @import("ConfigReloadEffects.zig");
model: *const client_model.Model,
events: [7]source_namespace.Event = undefined,
event_count: usize = 0,
commit: ?client_model.ConfigurationCommit = null,
apply_theme: ?bool = null,
sidebar: ?client_model.SidebarLayout = null,
observed_commit: bool = true,
failure: source_namespace.Failure = .none,

pub fn port(capture: *EffectsCapture) Effects {
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

fn record(capture: *EffectsCapture, event: source_namespace.Event) void {
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

pub fn eventSlice(capture: *const EffectsCapture) []const source_namespace.Event {
    return capture.events[0..capture.event_count];
}
