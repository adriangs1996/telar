const ModelType = @import("../../model/Model.zig");
const SidebarAnimationEffects = @import("SidebarAnimationEffects.zig");
const Capture = @This();

model: *const ModelType,
expected_revision: u64 = 0,
expected_frame: u8 = 0,
calls: usize = 0,
observed_commit: bool = false,
fail: bool = false,

pub fn effects(capture: *Capture) SidebarAnimationEffects {
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
