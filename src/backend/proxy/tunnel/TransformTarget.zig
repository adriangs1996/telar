const middleware = @import("../middleware.zig");
const TransformTarget = @This();

direction: middleware.Direction,
kind: middleware.HeaderKind,
stream_id: u32,
