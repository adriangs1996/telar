const EffectsCapture = @This();
const client_model = @import("../../root.zig").model;
const SidebarEffects = @import("SidebarEffects.zig");
model: *const client_model.Model,
calls: usize = 0,
observed_commit: bool = false,
change: ?client_model.SidebarLayout = null,
fail: bool = false,

pub fn port(capture: *EffectsCapture) SidebarEffects {
    return .{ .context = capture, .apply = apply };
}

fn apply(context: *anyopaque, change: client_model.SidebarLayout) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.change = change;
    capture.observed_commit = capture.model.sidebarVisible() == change.visible and
        capture.model.version().chrome == change.chrome_revision;

    if (capture.fail) {
        return error.SidebarSyncFailed;
    }
}
