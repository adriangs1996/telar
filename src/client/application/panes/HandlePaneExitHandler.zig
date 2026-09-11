const ModelType = @import("../../model/Model.zig");
const PaneExitEffects = @import("PaneExitEffects.zig");
const PaneIdType = @import("telar-core").PaneId;
const types = @import("../../model/types.zig");
const HandlePaneExitHandler = @This();

model: *ModelType,
effects: PaneExitEffects,

/// Commits pane retirement before releasing client resources. Stale exit
/// traffic still runs idempotent cleanup so pending requests can settle.
///
/// ```zig
/// const transition = try handler.execute(pane_id);
/// ```
pub fn execute(handler: *HandlePaneExitHandler, pane_id: PaneIdType) !types.PaneExit {
    const transition = handler.model.retirePane(pane_id);
    try handler.effects.deliver(handler.effects.context, transition);

    return transition;
}
