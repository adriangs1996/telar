const core = @import("telar-core");
const CommandType = @import("../history/Command.zig");
const AgentCommand = @This();

command: CommandType,
provider: []const u8,
tool_call_id: []const u8,
origin: core.HistoryOrigin,
phase: core.AgentCommandPhase = .finished,
redact: bool = true,
