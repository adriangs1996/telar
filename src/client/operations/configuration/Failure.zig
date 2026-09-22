const data = @import("model");
const Failure = @This();

generation: u64,
position: data.bar_values.Position,
reason: anyerror,
kind: []const u8,
