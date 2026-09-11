const Processing = @This();
const source_namespace = @import("root.zig");
const Stats = @import("Stats.zig");
current_size: source_namespace.schema.TerminalSize,
stats: *Stats,
