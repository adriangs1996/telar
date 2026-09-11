const RuntimeStopExecutorType = @import("../../application/commands/RuntimeStopExecutor.zig");
const ClientKeyType = @import("../../../history/ClientKey.zig");
const Controller = @This();

runtime_stop: RuntimeStopExecutorType,

/// Creates a controller around the runtime-stop application command.
///
/// ```zig
/// var controller = Controller.init(handler.executor());
/// ```
pub fn init(runtime_stop: RuntimeStopExecutorType) Controller {
    return .{ .runtime_stop = runtime_stop };
}

/// Attributes the payload-free wire request to its runtime-assigned client.
/// Delivery of `runtime_stopping` is a command effect, so this method does
/// not enqueue a requester-only response.
///
/// ```zig
/// controller.runtimeStop(client);
/// ```
pub fn runtimeStop(controller: *Controller, client: ClientKeyType) void {
    _ = controller.runtime_stop.execute(.{ .requester = client });
}
