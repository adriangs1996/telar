const core = @import("telar-core");
const Stats = @import("Stats.zig");
const Processing = @This();

current_size: core.TerminalSize,
stats: *Stats,
