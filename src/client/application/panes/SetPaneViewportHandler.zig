const ModelType = @import("../../model/Model.zig");
const PaneViewportEffects = @import("PaneViewportEffects.zig");
const PaneViewportCommand = @import("../../model/PaneViewportCommand.zig");
const PaneViewportChangeType = @import("../../model/PaneViewportChange.zig");
const SetPaneViewportHandler = @This();

model: *ModelType,
effects: PaneViewportEffects,

/// Commits a bounded client viewport before synchronizing graphics and
/// the runtime. Invalid targets and repeated offsets have no effects.
///
/// ```zig
/// const change = try handler.execute(command) orelse return;
/// ```
pub fn execute(handler: *SetPaneViewportHandler, command: PaneViewportCommand) !?PaneViewportChangeType {
    const change = handler.model.setPaneViewport(command) orelse return null;

    try handler.effects.sync(handler.effects.context, change);
    return change;
}
