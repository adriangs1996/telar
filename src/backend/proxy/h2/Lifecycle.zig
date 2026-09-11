const middleware = @import("../middleware.zig");
const Lifecycle = @This();

phase: middleware.Phase,
stream_id: u32,
status_code: u16,
