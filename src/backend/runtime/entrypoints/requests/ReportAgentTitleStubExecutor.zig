const StubExecutor = @This();
const report_commands = @import("../../application/commands/report_agent_title.zig");
result: report_commands.ReportAgentTitleResult = .recorded,
command: ?report_commands.ReportAgentTitle = null,

pub fn execute(stub: *StubExecutor, command: report_commands.ReportAgentTitle) report_commands.ReportAgentTitleResult {
    stub.command = command;
    return stub.result;
}
