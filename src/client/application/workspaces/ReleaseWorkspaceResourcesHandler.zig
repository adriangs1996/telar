const ReleaseWorkspaceResourcesHandler = @This();
const client_model = @import("../../root.zig").model;
const ReleaseEffects = @import("ReleaseEffects.zig");
const pane_resource_release = @import("../panes/root.zig").pane_resource_release;
const pane_focus_reporting = @import("../panes/root.zig").pane_focus_reporting;
model: *client_model.Model,
effects: ReleaseEffects,

/// Remembers navigation before releasing each exact pane resource and
/// silently retiring any remaining reported focus.
///
/// ```zig
/// handler.execute(&departure);
/// ```
pub fn execute(handler: *ReleaseWorkspaceResourcesHandler, departure: *const client_model.WorkspaceDeparture) void {
    if (departure.bookmark) |bookmark| {
        handler.effects.remember_bookmark(handler.effects.context, bookmark);
    }

    var release_pane: pane_resource_release.ReleasePaneResourcesHandler = .{
        .model = handler.model,
        .effects = .{
            .context = handler.effects.context,
            .clear_graphics = handler.effects.clear_pane_graphics,
        },
    };
    for (departure.panes.slice()) |pane_id| {
        _ = release_pane.execute(pane_id);
    }

    var retire_focus: pane_focus_reporting.RetireReportedPaneFocusHandler = .{
        .model = handler.model,
    };
    _ = retire_focus.execute();
}
