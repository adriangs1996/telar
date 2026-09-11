const id = @import("../id.zig");
/// Reply for requests that succeed without producing data.
const RequestCompleted = @This();

request_id: id.RequestId,
