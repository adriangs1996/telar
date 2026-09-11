const Capture = @This();
const source_namespace = @import("shutdown_coordinator.zig");
const GenericShutdownCoordinatorCoordinator = @import("GenericShutdownCoordinatorCoordinator.zig").Type;
const std = @import("std");
state: *const source_namespace.State,
steps: [source_namespace.shutdown_order.len]source_namespace.Step = undefined,
len: usize = 0,
observed_wrong_state: bool = false,
coordinator: ?*GenericShutdownCoordinatorCoordinator(Capture) = null,
reenter: bool = false,

pub fn execute(capture: *Capture, step: source_namespace.Step) void {
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
