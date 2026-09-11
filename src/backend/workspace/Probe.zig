const WorkspaceIdType = @import("telar-core").WorkspaceId;
const max_cwd_bytes_module = @import("telar-core").max_cwd_bytes;
const Probe = @This();

workspace: WorkspaceIdType,
path: [max_cwd_bytes_module]u8 = undefined,
path_len: u16,

/// Borrows the path owned by this asynchronous request.
/// Example: `const path = probe.pathSlice();`.
pub fn pathSlice(probe: *const Probe) []const u8 {
    return probe.path[0..probe.path_len];
}
