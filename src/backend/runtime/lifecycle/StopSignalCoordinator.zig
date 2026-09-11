const Coordinator = @This();
const source_namespace = @import("stop_signal.zig");
const Scheduler = @import("Scheduler.zig");
const std = @import("std");
queue: ?*source_namespace.Io.Queue(u8),

/// Borrows an optional external queue for the coordinator's lifetime.
///
/// ```zig
/// const stop_signal = Coordinator.init(&queue);
/// ```
pub fn init(queue: ?*source_namespace.Io.Queue(u8)) Coordinator {
    return .{ .queue = queue };
}

/// Schedules one wait when an external stop queue is configured.
/// Disabled coordinators treat arming as a successful no-op.
///
/// ```zig
/// try stop_signal.arm(scheduler);
/// ```
pub fn arm(coordinator: Coordinator, scheduler: Scheduler) !void {
    const queue = coordinator.queue orelse return;
    try scheduler.schedule(queue);
}

/// Converts a successful signal completion into the terminal event-loop
/// action and preserves the exact source error on failure.
///
/// ```zig
/// if (try stop_signal.complete(result) == .stop) {
///     return;
/// }
/// ```
pub fn complete(coordinator: Coordinator, result: anyerror!void) !source_namespace.Completion {
    std.debug.assert(coordinator.queue != null);
    try result;
    return .stop;
}
