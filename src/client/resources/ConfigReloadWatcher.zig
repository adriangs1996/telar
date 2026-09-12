const WaitArgsType = @import("WaitArgs.zig");
/// Starts one configuration watch on the adapter's event loop; the loaded
/// or failed reload returns as the adapter's own event.
const ConfigReloadWatcher = @This();

context: *anyopaque,
start_fn: *const fn (*anyopaque, WaitArgsType) anyerror!void,

/// Example: `try args.watcher.start(wait_args);`.
pub fn start(port: ConfigReloadWatcher, args: WaitArgsType) !void {
    return port.start_fn(port.context, args);
}
