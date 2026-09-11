const client_requests = @import("../../connection/requests.zig");
const FailureCodeType = @import("telar-core").FailureCode;
const Command = @This();

continuation: client_requests.Continuation,
code: FailureCodeType,
/// Borrowed only for the synchronous notification publication.
message: []const u8,
