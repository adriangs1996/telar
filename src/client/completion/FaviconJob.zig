//! One favicon lookup the adapter runs off the interactive path: the
//! workspace root is copied in full so the worker borrows nothing.
const data = @import("model");
const core = @import("telar-core");
const Job = @This();

execution_id: data.FaviconsState.ExecutionId,
workspace: core.WorkspaceId,
/// Side of the sprite cell the image is resized to.
cell: u16,
cwd: [core.max_cwd_bytes]u8 = undefined,
cwd_len: u16 = 0,

/// Example: `const job: Job = .init(.{ .execution_id = id, .workspace = workspace, .cell = 32 }, "/home/me/telar");`
pub fn init(self: Job, cwd: []const u8) Job {
    var job = self;
    const len = @min(cwd.len, job.cwd.len);
    @memcpy(job.cwd[0..len], cwd[0..len]);
    job.cwd_len = @intCast(len);
    return job;
}

pub fn cwdSlice(self: *const Job) []const u8 {
    return self.cwd[0..self.cwd_len];
}
