//! The result the adapter delivers for one favicon lookup. A successful
//! image is heap-owned by the worker's allocation and released by the
//! controller or the adapter that consumes it.
const data = @import("model");
const core = @import("telar-core");
const ImageType = @import("FaviconImage.zig");
const Completion = @This();

execution_id: data.FaviconsState.ExecutionId,
workspace: core.WorkspaceId,
result: anyerror!*ImageType,
