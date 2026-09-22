const model = @import("../../bars/model.zig");
const Failure = @This();

generation: u64,
position: model.Position,
reason: anyerror,
kind: []const u8,
