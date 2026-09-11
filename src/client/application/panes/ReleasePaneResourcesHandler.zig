const ReleasePaneResourcesHandler = @This();
const client_model = @import("../../root.zig").model;
const Effects = @import("PaneResourceReleaseEffects.zig");
const source_namespace = @import("pane_resource_release.zig");
const ReleasedResources = @import("ReleasedResources.zig");
model: *client_model.Model,
effects: Effects,

/// Releases exact model-owned authorities before clearing physical pane
/// graphics. Repeated or unknown identities still clear stale graphics.
///
/// ```zig
/// const released = handler.execute(pane_id);
/// ```
pub fn execute(handler: *ReleasePaneResourcesHandler, pane_id: source_namespace.schema.PaneId) ReleasedResources {
    const released: ReleasedResources = .{
        .copy_mode = handler.model.releaseCopyMode(pane_id),
        .pane_paste = handler.model.releasePanePaste(pane_id),
        .reported_focus = handler.model.releaseReportedPaneFocus(pane_id),
    };

    handler.effects.clear_graphics(handler.effects.context, pane_id);

    return released;
}
