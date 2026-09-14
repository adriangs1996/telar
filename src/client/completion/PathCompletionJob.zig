//! One directory listing the adapter runs off the interactive path: the
//! expanded query is copied in full so the worker borrows nothing.
const ExecutionIdType = @import("../model/PathCompletionState.zig").ExecutionId;
const max_path_bytes_module = @import("../model/PathCompletionResult.zig").max_path_bytes;
const Job = @This();

execution_id: ExecutionIdType,
query: [max_path_bytes_module]u8 = undefined,
query_len: u16 = 0,

/// Example: `const job: Job = .init(id, "/home/me/sand");`
pub fn init(execution_id: ExecutionIdType, query: []const u8) Job {
    var job: Job = .{ .execution_id = execution_id };
    const len = @min(query.len, job.query.len);
    @memcpy(job.query[0..len], query[0..len]);
    job.query_len = @intCast(len);
    return job;
}

pub fn querySlice(job: *const Job) []const u8 {
    return job.query[0..job.query_len];
}
