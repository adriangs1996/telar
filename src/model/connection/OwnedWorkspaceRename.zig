const core = @import("telar-core");
const OwnedWorkspaceRename = @This();

request_id: core.RequestId,
workspace: core.WorkspaceLocation,
name: [core.max_tab_label_bytes]u8 = undefined,
len: u8,

pub fn slice(self: *const OwnedWorkspaceRename) []const u8 {
    return self.name[0..self.len];
}
