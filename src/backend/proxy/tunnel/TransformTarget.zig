const TransformTarget = @This();
const middleware = @import("../middleware.zig");
direction: middleware.Direction,
kind: middleware.HeaderKind,
stream_id: u32,
