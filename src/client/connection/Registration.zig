const RequestIdType = @import("telar-core").RequestId;
const client_requests = @import("requests.zig");
const Registration = @This();

request_id: RequestIdType,
continuation: client_requests.Continuation,
