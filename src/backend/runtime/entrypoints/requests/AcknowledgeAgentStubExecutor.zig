const StubExecutor = @This();
const acknowledge_agent_commands = @import("../../application/commands/acknowledge_agent.zig");
result: acknowledge_agent_commands.AcknowledgeAgentResult = .acknowledged,
call_count: usize = 0,
command: ?acknowledge_agent_commands.AcknowledgeAgent = null,

pub fn execute(stub: *StubExecutor, command: acknowledge_agent_commands.AcknowledgeAgent) acknowledge_agent_commands.AcknowledgeAgentResult {
    stub.call_count += 1;
    stub.command = command;
    return stub.result;
}
