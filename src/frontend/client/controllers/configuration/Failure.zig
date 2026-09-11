const Failure = @This();
const bars = @import("../../../bars/root.zig");
generation: u64,
position: bars.Position,
reason: anyerror,
kind: []const u8,
