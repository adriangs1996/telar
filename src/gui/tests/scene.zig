const std = @import("std");
const Session = @import("Session.zig");

test "native scene captures terminal and thread damage in the same presentation" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    const pane = session.gui.app.model.workspace.findPane(Session.pane_id).?;
    try std.testing.expectEqual(pane.id, session.gui.cursorTarget().pane_id);
    const layout = &session.gui.app.model.activeTabModel().?.layout;
    try std.testing.expect(layout.setSurface(pane.id, .thread));
    const token = try session.gui.prepare(&session.renderer);
    const commit = session.gui.lifecycle.active.?.delivery.commit;
    try std.testing.expectEqual(@as(u8, 1), commit.len);
    try std.testing.expectEqual(pane.id, commit.panes[0].pane_id);
    try std.testing.expect(session.renderer.quads.items().len > 0);
    try std.testing.expectEqual(session.renderer.atlas.?.version, session.renderer.last_page_version);
    try session.gui.complete(token, true);
    try session.settle();
    try std.testing.expectEqual(@as(u64, 0), pane.pending_frame_id);
}

test "native copy selection recolors only projected cells and restores retained ink" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    const pane = session.gui.app.model.workspace.findPane(Session.pane_id).?;
    const canonical = pane.buffer.cells[0];
    const view = session.gui.app.model.activeTabModel().?.viewForPane(pane.id, session.gui.region.area).?;
    const position = [2]u16{ view.content.x, view.content.y };
    var projection = session.gui.projection();
    _ = try session.renderer.prepare(projection);
    const original = session.renderer.retained.at(position).items()[0];
    projection.copy = .{ .pane_id = pane.id, .view = .{ .cursor = .{ .x = 0, .y = pane.scroll.offset }, .anchor = .{ .x = 0, .y = pane.scroll.offset }, .linewise = false } };
    _ = try session.renderer.prepare(projection);
    try std.testing.expectEqual(@as(usize, 1), session.renderer.repainted_cells);
    const selected = session.renderer.retained.at(position).items()[0];
    try std.testing.expect(original.r != selected.r or original.g != selected.g or original.b != selected.b);
    try std.testing.expectEqualDeep(canonical, pane.buffer.cells[0]);
    projection.copy = null;
    _ = try session.renderer.prepare(projection);
    try std.testing.expectEqualDeep(original, session.renderer.retained.at(position).items()[0]);
    try std.testing.expectEqual(@as(usize, 1), session.renderer.repainted_cells);
}

test "native prefix and chrome hover invalidate presentation without changing model state" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    const token = try session.gui.prepare(&session.renderer);
    try session.gui.complete(token, true);
    try session.settle();
    const version = session.gui.app.model.version();
    try session.gui.input.accept(.{ .kind = 4, .code = 'b', .mods = 4 });
    try session.gui.input.drain(&session.gui.app);
    try std.testing.expectEqualDeep(version, session.gui.app.model.version());
    _ = session.gui.lifecycle.observe(session.gui.observation());
    try std.testing.expect(session.gui.lifecycle.needsPreparation());
    try std.testing.expect(session.gui.projection().status_mode == .prefix);
    const prefix = try session.gui.prepare(&session.renderer);
    try session.gui.complete(prefix, true);
    try session.settle();
    _ = session.gui.chrome.pointer(.{ .x = 0, .y = 0, .kind = .move });
    _ = session.gui.lifecycle.observe(session.gui.observation());
    try std.testing.expect(session.gui.lifecycle.needsPreparation());
    try std.testing.expectEqualDeep(version, session.gui.app.model.version());
}
