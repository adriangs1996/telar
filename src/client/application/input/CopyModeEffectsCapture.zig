const EffectsCapture = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("copy_mode.zig");
const input_capability = @import("../../input/root.zig");
const link_capability = @import("../../links/root.zig");
const CopyModeEffects = @import("CopyModeEffects.zig");
model: *client_model.Model,
copy_calls: usize = 0,
viewport_calls: usize = 0,
copy_observed_active: bool = false,
viewport_observed_commit: bool = false,
viewport_observed_active: bool = false,
copied: ?source_namespace.schema.CopySelection = null,
viewport: ?client_model.PaneViewportChange = null,
fail_copy: bool = false,
search_opened: ?input_capability.copy_mode.Direction = null,
link_opened: ?link_capability.Target = null,
fail_viewport: bool = false,

pub fn port(capture: *EffectsCapture) CopyModeEffects {
    return .{
        .context = capture,
        .copy = copy,
        .open_search = openSearch,
        .open_link = openLink,
        .viewport = .{
            .context = capture,
            .sync = syncViewport,
        },
    };
}

fn openSearch(context: *anyopaque, direction: input_capability.copy_mode.Direction) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.search_opened = direction;
}

fn openLink(context: *anyopaque, target: link_capability.Target) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.link_opened = target;
}

fn copy(context: *anyopaque, selection: source_namespace.schema.CopySelection) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.copy_calls += 1;
    capture.copy_observed_active = capture.model.copyModeActive();
    capture.copied = selection;

    if (capture.fail_copy) {
        return error.CopyDeliveryFailed;
    }
}

fn syncViewport(context: *anyopaque, viewport: client_model.PaneViewportChange) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    const pane = capture.model.workspace.findPane(viewport.pane_id).?;
    capture.viewport_calls += 1;
    capture.viewport = viewport;
    capture.viewport_observed_commit = pane.scroll.offset == viewport.offset;
    capture.viewport_observed_active = capture.model.copyModeActive();

    if (capture.fail_viewport) {
        return error.ViewportSyncFailed;
    }
}

pub fn reset(capture: *EffectsCapture) void {
    capture.copy_calls = 0;
    capture.viewport_calls = 0;
    capture.copy_observed_active = false;
    capture.viewport_observed_commit = false;
    capture.viewport_observed_active = false;
    capture.copied = null;
    capture.viewport = null;
}
