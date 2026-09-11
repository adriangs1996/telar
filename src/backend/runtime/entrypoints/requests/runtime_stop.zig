//! Protocol controller for the payload-free runtime-stop request.

const runtime_stop_commands = @import("../../application/commands/runtime_stop.zig");
const RuntimeStopStubExecutor = @import("RuntimeStopStubExecutor.zig");
const RuntimeStopController = @import("RuntimeStopController.zig");
const ClientKeyType = @import("../../../history/ClientKey.zig");
const std = @import("std");

test "Controller attributes runtime stop to the exact requesting client" {
    for ([_]runtime_stop_commands.RuntimeStopResult{ .requested, .already_requested }) |result| {
        var stub: RuntimeStopStubExecutor = .{ .result = result };
        var controller = RuntimeStopController.init(stub.executor());
        const client: ClientKeyType = .{ .id = 22, .generation = 6 };

        controller.runtimeStop(client);

        try std.testing.expectEqual(@as(usize, 1), stub.calls);
        try std.testing.expectEqualDeep(client, stub.command.?.requester);
    }
}
