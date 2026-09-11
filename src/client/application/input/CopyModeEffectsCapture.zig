const ModelType = @import("../../model/Model.zig");
const CopySelectionType = @import("telar-core").CopySelection;
const PaneViewportChangeType = @import("../../model/PaneViewportChange.zig");
const copy_mode_module = @import("../../input/copy_mode.zig");
const TargetType = @import("../../links/LinkTarget.zig");
const CopyModeEffects = @import("CopyModeEffects.zig");
const EffectsCapture = @This();

model: *ModelType,
copy_calls: usize = 0,
viewport_calls: usize = 0,
copy_observed_active: bool = false,
viewport_observed_commit: bool = false,
viewport_observed_active: bool = false,
copied: ?CopySelectionType = null,
viewport: ?PaneViewportChangeType = null,
fail_copy: bool = false,
search_opened: ?copy_mode_module.Direction = null,
link_opened: ?TargetType = null,
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

fn openSearch(context: *anyopaque, direction: copy_mode_module.Direction) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.search_opened = direction;
}

fn openLink(context: *anyopaque, target: TargetType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.link_opened = target;
}

fn copy(context: *anyopaque, selection: CopySelectionType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.copy_calls += 1;
    capture.copy_observed_active = capture.model.copyModeActive();
    capture.copied = selection;

    if (capture.fail_copy) {
        return error.CopyDeliveryFailed;
    }
}

fn syncViewport(context: *anyopaque, viewport: PaneViewportChangeType) !void {
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
