const report_commands = @import("../../application/commands/report_agent_title.zig");
const ReportAgentTitleType = @import("../../application/commands/ReportAgentTitle.zig");
const StubExecutor = @This();

result: report_commands.ReportAgentTitleResult = .recorded,
command: ?ReportAgentTitleType = null,

pub fn execute(stub: *StubExecutor, command: ReportAgentTitleType) report_commands.ReportAgentTitleResult {
    stub.command = command;
    return stub.result;
}
