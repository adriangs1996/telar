const report_commands = @import("../../application/commands/report_agent_session.zig");
const ReportAgentSessionType = @import("../../application/commands/ReportAgentSession.zig");
const StubExecutor = @This();

result: report_commands.ReportAgentSessionResult = .recorded,
command: ?ReportAgentSessionType = null,

pub fn execute(stub: *StubExecutor, command: ReportAgentSessionType) report_commands.ReportAgentSessionResult {
    stub.command = command;
    return stub.result;
}
