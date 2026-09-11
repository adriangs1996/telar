const shutdown_coordinator = @import("shutdown_coordinator.zig");
const GenericShutdownCoordinator = @import("GenericShutdownCoordinator.zig").Type;
const std = @import("std");
const Capture = @This();

state: *const shutdown_coordinator.State,
steps: [shutdown_coordinator.shutdown_order.len]shutdown_coordinator.Step = undefined,
len: usize = 0,
observed_wrong_state: bool = false,
coordinator: ?*GenericShutdownCoordinator(Capture) = null,
reenter: bool = false,

pub fn execute(capture: *Capture, step: shutdown_coordinator.Step) void {
    if (capture.state.* != .shutting_down) {
        capture.observed_wrong_state = true;
    }

    std.debug.assert(capture.len < capture.steps.len);
    capture.steps[capture.len] = step;
    capture.len += 1;

    if (capture.reenter and capture.len == 1) {
        capture.coordinator.?.run();
    }
}
