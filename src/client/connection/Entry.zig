const RequestIdType = @import("telar-core").RequestId;
const requests = @import("requests.zig");
const Entry = @This();

request_id: RequestIdType,
continuation: requests.Continuation,
