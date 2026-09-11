const OwnedWorkspaceRename = @This();
const source_namespace = @import("outbox_support.zig");
request_id: source_namespace.schema.RequestId,
workspace: source_namespace.schema.WorkspaceLocation,
name: [source_namespace.schema.max_tab_label_bytes]u8 = undefined,
len: u8,

pub fn slice(rename: *const OwnedWorkspaceRename) []const u8 {
    return rename.name[0..rename.len];
}
