const core = @import("telar-core");
const cmdcapture = @import("cmdcapture");
const Command = cmdcapture.Command;
const AgentCommand = @This();

command: Command,
provider: []const u8,
tool_call_id: []const u8,
origin: core.HistoryOrigin,
phase: core.AgentCommandPhase = .finished,
redact: bool = true,
