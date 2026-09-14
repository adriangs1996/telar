//! The next workspace whose favicon the registry wants looked up; the root
//! is borrowed from the workspace list snapshot for the call.
const WorkspaceIdType = @import("telar-core").WorkspaceId;

workspace: WorkspaceIdType,
cwd: []const u8,
