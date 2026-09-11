const ResizeHostHandler = @This();
const client_model = @import("../../root.zig").model;
const Effects = @import("HostResizeEffects.zig");
model: *client_model.Model,
effects: Effects,

/// Commits one measured host state before synchronizing disposable resources.
///
/// ```zig
/// const commit = try handler.execute(update) orelse return;
/// ```
pub fn execute(handler: *ResizeHostHandler, update: client_model.HostUpdate) !?client_model.HostCommit {
    const commit = try handler.model.reconcileHost(update) orelse return null;

    try handler.effects.deliver(handler.effects.context, commit);
    return commit;
}
