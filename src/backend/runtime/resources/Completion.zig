const Completion = @This();
const source_namespace = @import("git_probe.zig");
workspace: source_namespace.schema.WorkspaceId,
present: bool = false,
branch: [source_namespace.schema.max_git_branch_bytes]u8 = undefined,
branch_len: u8 = 0,
dirty: bool = false,

pub fn branchSlice(completion: *const Completion) []const u8 {
    return completion.branch[0..completion.branch_len];
}
