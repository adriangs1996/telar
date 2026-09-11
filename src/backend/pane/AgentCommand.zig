const CommandType = @import("../history/Command.zig");
const HistoryOriginType = @import("telar-core").HistoryOrigin;
const AgentCommandPhaseType = @import("telar-core").AgentCommandPhase;
const AgentCommand = @This();

command: CommandType,
provider: []const u8,
tool_call_id: []const u8,
origin: HistoryOriginType,
phase: AgentCommandPhaseType = .finished,
redact: bool = true,
