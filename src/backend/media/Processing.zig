const TerminalSizeType = @import("telar-core").TerminalSize;
const Stats = @import("Stats.zig");
const Processing = @This();

current_size: TerminalSizeType,
stats: *Stats,
