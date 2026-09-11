const ModelType = @import("../../model/Model.zig");
const FocusEffects = @import("FocusEffects.zig");
const PaneFocusRequest = @import("../../model/PaneFocusRequest.zig");
const PaneFocusType = @import("../../model/PaneFocus.zig");
const FocusPaneHandler = @This();

model: *ModelType,
effects: FocusEffects,

/// Commits one focus change before delivering it to active-pane resources.
/// A rejected or repeated target has no effects.
///
/// ```zig
/// const focus = try handler.execute(.{ .target = .{ .pane_id = pane_id }, .area = area });
/// ```
pub fn execute(handler: *FocusPaneHandler, command: PaneFocusRequest) !?PaneFocusType {
    const focus = handler.model.focusPane(command) orelse return null;

    try handler.effects.deliver(handler.effects.context, focus, command.area);
    return focus;
}
