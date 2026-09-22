const core = @import("telar-core");
const CommandContextType = @import("CommandContext.zig");
const CommandType = @import("Command.zig");
const AgentCommandRecord = @This();

context: CommandContextType,
command: CommandType,
provider: []const u8 = "",
tool_call_id: []const u8 = "",
origin: core.HistoryOrigin,
phase: core.AgentCommandPhase = .finished,
redact: bool = true,
