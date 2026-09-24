const core = @import("telar-core");
const CommandContext = @import("CommandContext.zig");
const cmdcapture = @import("cmdcapture");
const Command = cmdcapture.Command;
const AgentCommandRecord = @This();

context: CommandContext,
command: Command,
provider: []const u8 = "",
tool_call_id: []const u8 = "",
origin: core.HistoryOrigin,
phase: core.AgentCommandPhase = .finished,
redact: bool = true,
