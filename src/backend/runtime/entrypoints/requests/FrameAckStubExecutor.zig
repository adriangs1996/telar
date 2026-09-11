const frame_ack_commands = @import("../../application/commands/frame_ack.zig");
const AcknowledgeFrameType = @import("../../application/commands/AcknowledgeFrame.zig");
const StubExecutor = @This();

result: frame_ack_commands.FrameAckResult = .{ .acknowledged = 0 },
failure: ?anyerror = null,
call_count: usize = 0,
command: ?AcknowledgeFrameType = null,

pub fn execute(stub: *StubExecutor, command: AcknowledgeFrameType) !frame_ack_commands.FrameAckResult {
    stub.call_count += 1;
    stub.command = command;

    if (stub.failure) |failure| {
        return failure;
    }

    return stub.result;
}
