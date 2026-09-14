//! One favicon lookup the adapter runs off the interactive path: the
//! workspace root is copied in full so the worker borrows nothing.
const ExecutionIdType = @import("../controllers/workspaces/FaviconsState.zig").ExecutionId;
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const max_cwd_bytes = @import("telar-core").max_cwd_bytes;
const Job = @This();

execution_id: ExecutionIdType,
workspace: WorkspaceIdType,
/// Side of the sprite cell the image is resized to.
cell: u16,
cwd: [max_cwd_bytes]u8 = undefined,
cwd_len: u16 = 0,

/// Example: `const job: Job = .init(.{ .execution_id = id, .workspace = workspace, .cell = 32 }, "/home/me/telar");`
pub fn init(identity: Job, cwd: []const u8) Job {
    var job = identity;
    const len = @min(cwd.len, job.cwd.len);
    @memcpy(job.cwd[0..len], cwd[0..len]);
    job.cwd_len = @intCast(len);
    return job;
}

pub fn cwdSlice(job: *const Job) []const u8 {
    return job.cwd[0..job.cwd_len];
}
