const model = @import("../bars/model.zig");
const BarUpdateInput = @This();

generation: u64,
position: model.Position,
content: model.Content,
