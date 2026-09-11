//! Protocol controller for the payload-free runtime-stop request.

const std = @import("std");
const runtime_stop_commands = @import("../../application/commands/runtime_stop.zig");
const shutdown_mod = @import("../../lifecycle/root.zig").shutdown_authority;

pub const Controller = @import("RuntimeStopController.zig");

const StubExecutor = @import("RuntimeStopStubExecutor.zig");

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
