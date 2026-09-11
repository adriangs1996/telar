const ModelType = @import("../../model/Model.zig");
const PaneResourceReleaseEffects = @import("PaneResourceReleaseEffects.zig");
const PaneIdType = @import("telar-core").PaneId;
const ReleasedResources = @import("ReleasedResources.zig");
const ReleasePaneResourcesHandler = @This();

model: *ModelType,
effects: PaneResourceReleaseEffects,

/// Releases exact model-owned authorities before clearing physical pane
/// graphics. Repeated or unknown identities still clear stale graphics.
///
/// ```zig
/// const released = handler.execute(pane_id);
/// ```
pub fn execute(handler: *ReleasePaneResourcesHandler, pane_id: PaneIdType) ReleasedResources {
    const released: ReleasedResources = .{
        .copy_mode = handler.model.releaseCopyMode(pane_id),
        .pane_paste = handler.model.releasePanePaste(pane_id),
        .reported_focus = handler.model.releaseReportedPaneFocus(pane_id),
    };

    handler.effects.clear_graphics(handler.effects.context, pane_id);

    return released;
}
