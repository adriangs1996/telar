const Update = @This();
const source_namespace = @import("model.zig");
const Content = @import("Content.zig");
generation: u64,
position: source_namespace.Position,
content: Content,
