//! What the adapter asks the favicon operation to look up: the workspace,
//! its root and the sprite cell side the image is resized to. The root is
//! borrowed only for the call; the job copies it.
const core = @import("telar-core");

workspace: core.WorkspaceId,
cwd: []const u8,
cell: u16,
