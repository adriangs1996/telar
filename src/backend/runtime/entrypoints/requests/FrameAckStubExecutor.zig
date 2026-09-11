const StubExecutor = @This();
const frame_ack_commands = @import("../../application/commands/frame_ack.zig");
result: frame_ack_commands.FrameAckResult = .{ .acknowledged = 0 },
failure: ?anyerror = null,
call_count: usize = 0,
command: ?frame_ack_commands.AcknowledgeFrame = null,

pub fn execute(stub: *StubExecutor, command: frame_ack_commands.AcknowledgeFrame) !frame_ack_commands.FrameAckResult {
    stub.call_count += 1;
    stub.command = command;

    if (stub.failure) |failure| {
        return failure;
    }

    return stub.result;
}
