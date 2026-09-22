//! One landed lookup: the workspace it answers and its image, or null when
//! the lookup found nothing usable.
const core = @import("telar-core");
const client = @import("telar-client");

workspace: core.WorkspaceId,
image: ?*client.FaviconImage,
