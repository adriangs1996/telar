const core = @import("telar-core");
const Stats = @import("Stats.zig");
const Processing = @This();

cwd: ?[]const u8,
current_size: core.TerminalSize,
stats: *Stats,
provider: core.AgentProvider = .unknown,
