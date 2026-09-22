const core = @import("telar-core");
const requests = @import("requests.zig");
const Entry = @This();

request_id: core.RequestId,
continuation: requests.Continuation,
