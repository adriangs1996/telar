const data = @import("model");
const BarCommandFailure = @This();

generation: u64,
position: data.bar_values.Position,
reason: anyerror,
kind: []const u8,
