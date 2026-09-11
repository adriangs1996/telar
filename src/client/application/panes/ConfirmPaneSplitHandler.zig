const ModelType = @import("../../model/Model.zig");
const ConfirmationEffects = @import("ConfirmationEffects.zig");
const ConfirmPaneSplit = @import("ConfirmPaneSplit.zig");
const PaneSplitCommitType = @import("../../model/PaneSplitCommit.zig");
const std = @import("std");
const ConfirmPaneSplitHandler = @This();

model: *ModelType,
effects: ConfirmationEffects,

/// Validates the exact runtime reply, commits the passive model and only
/// then synchronizes client resources.
///
/// ```zig
/// const commit = try handler.execute(command);
/// ```
pub fn execute(handler: *ConfirmPaneSplitHandler, command: ConfirmPaneSplit) !PaneSplitCommitType {
    if (!command.created or
        command.confirmed_pane == command.requested.target_pane or
        !std.meta.eql(command.confirmed_location, command.requested.location))
    {
        return error.UnexpectedPane;
    }

    const commit = try handler.model.commitPaneSplit(.{
        .split = command.requested,
        .new_pane = command.confirmed_pane,
    });
    try handler.effects.deliver(handler.effects.context, commit);

    return commit;
}
