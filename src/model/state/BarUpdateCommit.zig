const model = @import("../bars/model.zig");
const BarUpdateCommit = @This();

generation: u64,
position: model.Position,
bars_revision: u64,
