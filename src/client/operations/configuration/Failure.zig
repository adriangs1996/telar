const PositionType = @import("../../bars/model.zig").Position;
const Failure = @This();

generation: u64,
position: PositionType,
reason: anyerror,
kind: []const u8,
