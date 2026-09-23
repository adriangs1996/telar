const core = @import("telar-core");
const ResourceState = @import("../panes/ResourceState.zig");

pub const PaneGraphicsResourceResult = union(enum) {
    unchanged,
    changed: ResourceState,
    resync_required: core.PaneId,
    shared_mapping_failed: core.PaneId,
};
