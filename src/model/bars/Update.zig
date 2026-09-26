const model = @import("model.zig");
const Update = @This();

generation: u64,
position: model.Position,
content: model.Content,
