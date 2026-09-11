const EffectCapture = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("host_resource_delivery.zig");
const SidebarConfiguration = @import("SidebarConfiguration.zig");
const Effects = @import("HostResourceDeliveryEffects.zig");
const std = @import("std");
model: *const client_model.Model,
commit: client_model.HostCommit,
events: [10]source_namespace.Event = undefined,
event_count: usize = 0,
sidebar_configurations: [2]SidebarConfiguration = undefined,
sidebar_configuration_count: usize = 0,
committed_state_observed: bool = true,
failure: source_namespace.Failure = .none,
appearance: ?client_model.HostAppearance = null,

pub fn effects(capture: *EffectCapture) Effects {
    return .{
        .context = capture,
        .sync_graphics_fallbacks = syncGraphicsFallbacks,
        .configure_sidebar = configureSidebar,
        .invalidate_graphics_placements = invalidateGraphicsPlacements,
        .resize_presenter = resizePresenter,
        .resize_view = resizeView,
        .sync_pane_geometry = syncPaneGeometry,
        .apply_appearance = applyAppearance,
        .sync_terminal_colors = syncTerminalColors,
    };
}

fn syncTerminalColors(_: *anyopaque, _: source_namespace.schema.TerminalColors) !void {}

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

fn resizePresenter(context: *anyopaque, size: source_namespace.schema.TerminalSize) !void {
    const capture: *EffectCapture = @ptrCast(@alignCast(context));
    capture.append(.presenter_resize);
    const resize = capture.commit.resize.?;
    capture.committed_state_observed = capture.committed_state_observed and
        std.meta.eql(size, resize.current);

    if (capture.failure == .presenter_resize) {
        return error.PresenterResizeFailed;
    }
}

fn resizeView(context: *anyopaque, size: source_namespace.schema.TerminalSize) !void {
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

fn append(capture: *EffectCapture, event: source_namespace.Event) void {
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

pub fn eventSlice(capture: *const EffectCapture) []const source_namespace.Event {
    return capture.events[0..capture.event_count];
}
