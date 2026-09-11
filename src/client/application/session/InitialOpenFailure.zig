const InitialOpenFailure = @This();
const client_requests = @import("../../connection/root.zig").requests;
const source_namespace = @import("request_failure.zig");
open: client_requests.InitialOpen,
code: source_namespace.schema.FailureCode,
