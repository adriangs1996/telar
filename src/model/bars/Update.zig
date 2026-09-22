const model = @import("model.zig");
const Content = @import("Content.zig");
const Update = @This();

generation: u64,
position: model.Position,
content: Content,
