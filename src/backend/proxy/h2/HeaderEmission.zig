const HeaderEmission = @This();
const source_namespace = @import("relay.zig");
const middleware = @import("../middleware.zig");
direction: source_namespace.Direction,
stream_id: u32,
headers: *const middleware.Headers,
