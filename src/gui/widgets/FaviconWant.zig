//! The next workspace whose favicon the registry wants looked up; the root
//! is borrowed from the workspace list snapshot for the call.
const core = @import("telar-core");

workspace: core.WorkspaceId,
cwd: []const u8,
