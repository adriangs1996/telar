const model = @import("../bars/model.zig");
const ContentType = @import("../bars/Content.zig");
const BarUpdateInput = @This();

generation: u64,
position: model.Position,
content: ContentType,
