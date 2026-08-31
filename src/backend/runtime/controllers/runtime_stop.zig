//! Protocol controller for the payload-free runtime-stop request.

const std = @import("std");
const runtime_stop_commands = @import("../commands/runtime_stop.zig");
const shutdown_mod = @import("../lifecycle/root.zig").shutdown_authority;

pub const Controller = struct {
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
};

const StubExecutor = struct {
    result: runtime_stop_commands.RuntimeStopResult,
    calls: usize = 0,
    command: ?runtime_stop_commands.RuntimeStop = null,

    fn executor(stub: *StubExecutor) runtime_stop_commands.RuntimeStopExecutor {
        return .{ .context = stub, .execute_fn = execute };
    }

    fn execute(context: *anyopaque, command: runtime_stop_commands.RuntimeStop) runtime_stop_commands.RuntimeStopResult {
        const stub: *StubExecutor = @ptrCast(@alignCast(context));
        stub.calls += 1;
        stub.command = command;
        return stub.result;
    }
};

test "Controller attributes runtime stop to the exact requesting client" {
    for ([_]runtime_stop_commands.RuntimeStopResult{ .requested, .already_requested }) |result| {
        var stub: StubExecutor = .{ .result = result };
        var controller = Controller.init(stub.executor());
        const client: shutdown_mod.ClientKey = .{ .id = 22, .generation = 6 };

        controller.runtimeStop(client);

        try std.testing.expectEqual(@as(usize, 1), stub.calls);
        try std.testing.expectEqualDeep(client, stub.command.?.requester);
    }
}
