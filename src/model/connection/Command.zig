const core = @import("telar-core");
const client_requests = @import("requests.zig");
const Command = @This();

continuation: client_requests.Continuation,
code: core.FailureCode,
/// Borrowed only for the synchronous notification publication.
message: []const u8,
