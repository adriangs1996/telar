const ModelType = @import("../../model/Model.zig");
const HostResizeEffects = @import("HostResizeEffects.zig");
const HostUpdateType = @import("../../model/HostUpdate.zig");
const HostCommitType = @import("../../model/HostCommit.zig");
const ResizeHostHandler = @This();

model: *ModelType,
effects: HostResizeEffects,

/// Commits one measured host state before synchronizing disposable resources.
///
/// ```zig
/// const commit = try handler.execute(update) orelse return;
/// ```
pub fn execute(handler: *ResizeHostHandler, update: HostUpdateType) !?HostCommitType {
    const commit = try handler.model.reconcileHost(update) orelse return null;

    try handler.effects.deliver(handler.effects.context, commit);
    return commit;
}
