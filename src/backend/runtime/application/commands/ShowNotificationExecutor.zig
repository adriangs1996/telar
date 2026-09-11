const ShowNotification = @import("ShowNotification.zig");
const ShowNotificationResult = @import("ShowNotificationResult.zig");
const ShowNotificationExecutor = @This();

context: *anyopaque,
execute_fn: *const fn (*anyopaque, ShowNotification) ShowNotificationResult,

/// Executes the bound notification use case synchronously.
///
/// ```zig
/// const result = executor.execute(.{ .notification = notification });
/// ```
pub fn execute(executor: ShowNotificationExecutor, command: ShowNotification) ShowNotificationResult {
    return executor.execute_fn(executor.context, command);
}
