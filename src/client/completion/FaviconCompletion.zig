//! The result the adapter delivers for one favicon lookup. A successful
//! image is heap-owned by the worker's allocation and released by the
//! controller or the adapter that consumes it. A lookup that stopped at a
//! limit carries its reach, which `favicons.complete` reports on the loop.
const data = @import("model");
const core = @import("telar-core");
const FaviconImage = @import("FaviconImage.zig");
const Completion = @This();

execution_id: data.FaviconsState.ExecutionId,
workspace: core.WorkspaceId,
result: anyerror!*FaviconImage,
/// The limit the lookup stopped at, reported where the completion lands.
limit: ?core.LimitReach = null,
