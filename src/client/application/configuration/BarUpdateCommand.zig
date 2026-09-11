const Command = @This();
const bars = @import("../../bars/root.zig");
const source_namespace = @import("bar_update.zig");
generation: u64,
position: bars.Position,
result: source_namespace.Result,
