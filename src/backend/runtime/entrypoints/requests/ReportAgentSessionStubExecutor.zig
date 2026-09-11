const StubExecutor = @This();
const report_commands = @import("../../application/commands/report_agent_session.zig");
result: report_commands.ReportAgentSessionResult = .recorded,
command: ?report_commands.ReportAgentSession = null,

pub fn execute(stub: *StubExecutor, command: report_commands.ReportAgentSession) report_commands.ReportAgentSessionResult {
    stub.command = command;
    return stub.result;
}
