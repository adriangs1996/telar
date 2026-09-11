const CommandContextType = @import("CommandContext.zig");
const CommandType = @import("Command.zig");
const HistoryOriginType = @import("telar-core").HistoryOrigin;
const AgentCommandPhaseType = @import("telar-core").AgentCommandPhase;
const AgentCommandRecord = @This();

context: CommandContextType,
command: CommandType,
provider: []const u8 = "",
tool_call_id: []const u8 = "",
origin: HistoryOriginType,
phase: AgentCommandPhaseType = .finished,
redact: bool = true,
