const TerminalSizeType = @import("telar-core").TerminalSize;
const Stats = @import("Stats.zig");
const AgentProviderType = @import("telar-core").AgentProvider;
const Processing = @This();

cwd: ?[]const u8,
current_size: TerminalSizeType,
stats: *Stats,
provider: AgentProviderType = .unknown,
