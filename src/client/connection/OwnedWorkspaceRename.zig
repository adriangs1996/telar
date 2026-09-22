const core = @import("telar-core");
const OwnedWorkspaceRename = @This();

request_id: core.RequestId,
workspace: core.WorkspaceLocation,
name: [core.max_tab_label_bytes]u8 = undefined,
len: u8,

pub fn slice(rename: *const OwnedWorkspaceRename) []const u8 {
    return rename.name[0..rename.len];
}
