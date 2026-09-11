const ReportAgentResultType = @import("../../application/commands/ReportAgentResult.zig");
const ReportAgentType = @import("../../application/commands/ReportAgent.zig");
const StubExecutor = @This();

result: ReportAgentResultType = .{ .outcome = .applied },
command: ?ReportAgentType = null,

pub fn execute(stub: *StubExecutor, command: ReportAgentType) ReportAgentResultType {
    stub.command = command;
    return stub.result;
}
