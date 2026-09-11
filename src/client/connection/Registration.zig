const Registration = @This();
const schema = @import("telar-core").schema;
const client_requests = @import("requests.zig");
request_id: schema.RequestId,
continuation: client_requests.Continuation,
