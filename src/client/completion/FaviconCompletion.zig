//! The result the adapter delivers for one favicon lookup. A successful
//! image is heap-owned by the worker's allocation and released by the
//! controller or the adapter that consumes it.
const ExecutionIdType = @import("../controllers/workspaces/FaviconsState.zig").ExecutionId;
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const ImageType = @import("FaviconImage.zig");
const Completion = @This();

execution_id: ExecutionIdType,
workspace: WorkspaceIdType,
result: anyerror!*ImageType,
