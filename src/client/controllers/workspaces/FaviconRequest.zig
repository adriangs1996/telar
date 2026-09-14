//! What the adapter asks the favicon controller to look up: the workspace,
//! its root and the sprite cell side the image is resized to. The root is
//! borrowed only for the call; the job copies it.
const WorkspaceIdType = @import("telar-core").WorkspaceId;

workspace: WorkspaceIdType,
cwd: []const u8,
cell: u16,
