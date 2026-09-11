const tracker_support = @import("../../../agent/tracker_support.zig");
const AcknowledgeAgentType = @import("../../application/commands/AcknowledgeAgent.zig");
const StubExecutor = @This();

result: tracker_support.AcknowledgeResult = .acknowledged,
call_count: usize = 0,
command: ?AcknowledgeAgentType = null,

pub fn execute(stub: *StubExecutor, command: AcknowledgeAgentType) tracker_support.AcknowledgeResult {
    stub.call_count += 1;
    stub.command = command;
    return stub.result;
}
