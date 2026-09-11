const request_support = @import("../provider/request_support.zig");
const types = @import("types.zig");
/// Owned metadata derived from one forwarded request head.
const RequestHead = @This();

classification: request_support.RequestClass,
body: types.BodyPlan,
response_context: types.ResponseContext,
