const core = @import("telar-core");
const Probe = @This();

workspace: core.WorkspaceId,
path: [core.max_cwd_bytes]u8 = undefined,
path_len: u16,

/// Borrows the path owned by this asynchronous request.
/// Example: `const path = probe.pathSlice();`.
pub fn pathSlice(self: *const Probe) []const u8 {
    return self.path[0..self.path_len];
}
