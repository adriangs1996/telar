const SelectTabHandler = @This();
const client_model = @import("../../root.zig").model;
const SnapshotGate = @import("SnapshotGate.zig");
const SelectionEffects = @import("SelectionEffects.zig");
const SelectTab = @import("SelectTab.zig");
model: *client_model.Model,
snapshots: SnapshotGate,
effects: SelectionEffects,

/// Commits the active identity before synchronizing client resources.
/// Missing, repeated and snapshot-blocked selections have no effects.
///
/// ```zig
/// const selection = try handler.execute(.{ .target = .{ .tab_id = tab_id } });
/// ```
pub fn execute(handler: *SelectTabHandler, command: SelectTab) !?client_model.TabSelection {
    if (handler.snapshots.pending(handler.snapshots.context)) {
        return null;
    }

    const selection = handler.model.selectTab(command.target) catch |err| switch (err) {
        error.NoActiveTab, error.TabNotFound => return null,
    } orelse return null;

    try handler.effects.deliver(handler.effects.context, selection);
    return selection;
}
