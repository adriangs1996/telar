const StateType = @import("../../lifecycle/State.zig");
const Notifications = @import("Notifications.zig");
const RuntimeStop = @import("RuntimeStop.zig");
const runtime_stop = @import("runtime_stop.zig");
const RuntimeStopExecutor = @import("RuntimeStopExecutor.zig");
const RuntimeStopHandler = @This();

shutdown: *StateType,
notifications: Notifications,

/// Commits first-writer shutdown authority before publishing exactly one
/// typed notification. Repeated commands have no effect.
///
/// ```zig
/// const result = handler.execute(.{ .requester = client });
/// ```
pub fn execute(handler: *RuntimeStopHandler, command: RuntimeStop) runtime_stop.RuntimeStopResult {
    const event = handler.shutdown.request(command.requester) orelse {
        return .already_requested;
    };

    handler.notifications.publish(event);
    return .requested;
}

/// Exposes this handler through the command interface used by controllers.
///
/// ```zig
/// const executor = handler.executor();
/// ```
pub fn executor(handler: *RuntimeStopHandler) RuntimeStopExecutor {
    return .{ .context = handler, .execute_fn = executeErased };
}

fn executeErased(context: *anyopaque, command: RuntimeStop) runtime_stop.RuntimeStopResult {
    const handler: *RuntimeStopHandler = @ptrCast(@alignCast(context));
    return handler.execute(command);
}
