//! One landed lookup: the workspace it answers and its image, or null when
//! the lookup found nothing usable.
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const ImageType = @import("telar-client").FaviconImage;

workspace: WorkspaceIdType,
image: ?*ImageType,
