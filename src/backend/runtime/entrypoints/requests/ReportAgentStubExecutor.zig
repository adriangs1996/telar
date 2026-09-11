const StubExecutor = @This();
const report_commands = @import("../../application/commands/report_agent.zig");
result: report_commands.ReportAgentResult = .{ .outcome = .applied },
command: ?report_commands.ReportAgent = null,

pub fn execute(stub: *StubExecutor, command: report_commands.ReportAgent) report_commands.ReportAgentResult {
    stub.command = command;
    return stub.result;
}
