const Controller = @This();
const runtime_stop_commands = @import("../../application/commands/runtime_stop.zig");
const shutdown_mod = @import("../../lifecycle/root.zig").shutdown_authority;
runtime_stop: runtime_stop_commands.RuntimeStopExecutor,

/// Creates a controller around the runtime-stop application command.
///
/// ```zig
/// var controller = Controller.init(handler.executor());
/// ```
pub fn init(runtime_stop: runtime_stop_commands.RuntimeStopExecutor) Controller {
    return .{ .runtime_stop = runtime_stop };
}

/// Attributes the payload-free wire request to its runtime-assigned client.
/// Delivery of `runtime_stopping` is a command effect, so this method does
/// not enqueue a requester-only response.
///
/// ```zig
/// controller.runtimeStop(client);
/// ```
pub fn runtimeStop(controller: *Controller, client: shutdown_mod.ClientKey) void {
    _ = controller.runtime_stop.execute(.{ .requester = client });
}
