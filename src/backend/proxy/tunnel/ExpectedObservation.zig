const middleware = @import("../middleware.zig");
const ExpectedObservation = @This();

phase: middleware.Phase,
stream_id: u32,
