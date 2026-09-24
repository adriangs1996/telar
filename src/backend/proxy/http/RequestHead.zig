const types = @import("types.zig");
/// Owned metadata derived from one forwarded request head.
const RequestHead = @This();

/// The original start line matched one of the watched routes.
watched: bool,
body: types.BodyPlan,
response_context: types.ResponseContext,
