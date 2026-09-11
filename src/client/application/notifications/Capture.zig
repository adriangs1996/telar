const Capture = @This();
const client_model = @import("../../root.zig").model;
const Effects = @import("SidebarAnimationEffects.zig");
model: *const client_model.Model,
expected_revision: u64 = 0,
expected_frame: u8 = 0,
calls: usize = 0,
observed_commit: bool = false,
fail: bool = false,

pub fn effects(capture: *Capture) Effects {
    return .{ .context = capture, .schedule = schedule };
}

fn schedule(raw_context: *anyopaque) !void {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    capture.calls += 1;
    capture.observed_commit = capture.model.version().sidebar_animation ==
        capture.expected_revision and
        capture.model.sidebarAnimationFrame() == capture.expected_frame;

    if (capture.fail) {
        return error.AnimationScheduleFailed;
    }
}
