const RequestIdType = @import("telar-core").RequestId;
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const OwnedWorkspaceRename = @This();

request_id: RequestIdType,
workspace: WorkspaceLocationType,
name: [max_tab_label_bytes_module]u8 = undefined,
len: u8,

pub fn slice(rename: *const OwnedWorkspaceRename) []const u8 {
    return rename.name[0..rename.len];
}
