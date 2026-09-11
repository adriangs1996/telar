const Command = @This();
const client_requests = @import("../../connection/root.zig").requests;
const source_namespace = @import("request_failure.zig");
continuation: client_requests.Continuation,
code: source_namespace.schema.FailureCode,
/// Borrowed only for the synchronous notification publication.
message: []const u8,
