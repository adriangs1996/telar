const Processing = @This();
const source_namespace = @import("observer_support.zig");
const Stats = @import("Stats.zig");
cwd: ?[]const u8,
current_size: source_namespace.schema.TerminalSize,
stats: *Stats,
provider: source_namespace.schema.AgentProvider = .unknown,
