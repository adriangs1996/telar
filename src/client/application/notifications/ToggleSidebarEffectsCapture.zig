const ModelType = @import("../../model/Model.zig");
const SidebarLayoutType = @import("../../model/SidebarLayout.zig");
const SidebarEffects = @import("SidebarEffects.zig");
const EffectsCapture = @This();

model: *const ModelType,
calls: usize = 0,
observed_commit: bool = false,
change: ?SidebarLayoutType = null,
fail: bool = false,

pub fn port(capture: *EffectsCapture) SidebarEffects {
    return .{ .context = capture, .apply = apply };
}

fn apply(context: *anyopaque, change: SidebarLayoutType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.change = change;
    capture.observed_commit = capture.model.sidebarVisible() == change.visible and
        capture.model.version().chrome == change.chrome_revision;

    if (capture.fail) {
        return error.SidebarSyncFailed;
    }
}
