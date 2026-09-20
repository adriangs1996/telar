const core = @import("telar-core");
const PaneStore = @import("../../../pane/PaneStore.zig");
const PaneKey = @import("../../../pane/PaneKey.zig");
const Pane = @import("../../../pane/Pane.zig");
const Session = @import("../../client/Session.zig");
const std = @import("std");
const Handler = @This();
panes: *PaneStore,
session: *Session,

/// Gives read-only controls a current generation while preserving UI attachment authority. Example: `const key = handler.execute(pane_id) orelse return;`
pub fn execute(self: *const Handler, pane_id: core.PaneId) ?PaneKey {
    if (self.session.role == .control) {
        const pane = self.panes.findRunning(pane_id) orelse return null;
        if (pane.exit != null) {
            return null;
        }

        return pane.key();
    }

    const attachment = self.session.attachments.find(pane_id) orelse return null;
    return attachment.pane.key();
}

test "headless searches capture a generation without granting UI attachment authority" {
    const pane = try std.testing.allocator.create(Pane);
    defer std.testing.allocator.destroy(pane);
    pane.id = @enumFromInt(7);
    pane.generation = 9;
    pane.launch_state = .running;
    pane.exit = null;
    var panes: PaneStore = .{};
    panes.items[0] = pane;
    panes.count = 1;
    panes.index.put(7, 0);
    var session: Session = undefined;
    session.role = .ui;
    session.attachments = .{};
    const handler: Handler = .{ .panes = &panes, .session = &session };
    try std.testing.expect(handler.execute(pane.id) == null);
    session.role = .control;
    const selected = handler.execute(pane.id).?;
    try std.testing.expectEqual(@as(u64, 9), selected.generation);
    pane.generation = 10;
    try std.testing.expect(panes.resolve(selected) == null);
    try std.testing.expect(handler.execute(@enumFromInt(99)) == null);
}
