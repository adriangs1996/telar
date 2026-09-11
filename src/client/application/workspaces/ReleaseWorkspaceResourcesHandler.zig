const ModelType = @import("../../model/Model.zig");
const ReleaseEffects = @import("ReleaseEffects.zig");
const WorkspaceDepartureType = @import("../../model/WorkspaceDeparture.zig");
const ReleasePaneResourcesHandlerType = @import("../panes/ReleasePaneResourcesHandler.zig");
const RetireReportedPaneFocusHandlerType = @import("../panes/RetireReportedPaneFocusHandler.zig");
const ReleaseWorkspaceResourcesHandler = @This();

model: *ModelType,
effects: ReleaseEffects,

/// Remembers navigation before releasing each exact pane resource and
/// silently retiring any remaining reported focus.
///
/// ```zig
/// handler.execute(&departure);
/// ```
pub fn execute(handler: *ReleaseWorkspaceResourcesHandler, departure: *const WorkspaceDepartureType) void {
    if (departure.bookmark) |bookmark| {
        handler.effects.remember_bookmark(handler.effects.context, bookmark);
    }

    var release_pane: ReleasePaneResourcesHandlerType = .{
        .model = handler.model,
        .effects = .{
            .context = handler.effects.context,
            .clear_graphics = handler.effects.clear_pane_graphics,
        },
    };
    for (departure.panes.slice()) |pane_id| {
        _ = release_pane.execute(pane_id);
    }

    var retire_focus: RetireReportedPaneFocusHandlerType = .{
        .model = handler.model,
    };
    _ = retire_focus.execute();
}
