const id = @import("../id.zig");
/// One-shot request for the limits the runtime and its clients reached.
/// The reply is `limit_list`.
const QueryLimits = @This();

request_id: id.RequestId,
