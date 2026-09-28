const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const input_support = @import("input_support.zig");
const review = @import("change_review.zig");
const Session = @import("Session.zig");

test "a secondary press on an agent card opens a drawable peek that reads its pane" {
    const session = try review.base();
    defer session.deinit();
    const gui = session.gui;
    const app = gui.app;
    var bytes: [4096]u8 = undefined;
    const snapshot = try core.encodeAgentSnapshot(&bytes, .{ .revision = 1, .entries = &.{.{
        .pane_id = Session.pane_id,
        .pane_generation = 1,
        .location = Session.location,
        .pane_index = 1,
        .process_id = 1,
        .session_id = @splat(0),
        .provider = .codex,
        .status = .working,
        .source = .lifecycle_report,
        .authority = .active,
        .confidence = 100,
        .sequence = 1,
        .observed_at_ms = 0,
        .expires_at_ms = 1000,
    }} });
    _ = try client.runtime_messages.handleServerMessage(app, try core.decodeServer(snapshot));
    try session.settle();
    try input_support.presented(gui, try session.draw(), true);

    const key = app.model.agent_snapshot.slice()[0].key;
    const card = gui.chrome.presented().band_hits.find(.{ .focus_agent = key });
    try std.testing.expect(card != null);
    const intent = client.secondaryIntent(.{ .focus_agent = key });
    _ = try client.view_interactions.apply(app, app.model.tabs.active, .{ .intent = intent, .consumed = true });

    const prompt = app.model.name_prompt.currentConst().?;
    try std.testing.expectEqualDeep(key, prompt.target().peek);
    try std.testing.expect(app.model.peek_screen.reading);
    const read = (try core.decodeClient(try session.sent())).read_pane;
    try std.testing.expectEqual(Session.pane_id, read.pane_id);
    try session.settle();
    try input_support.presented(gui, try session.draw(), true);
    try std.testing.expectEqual(Session.pane_id, app.model.tabs.layout[app.model.tabs.active].focused().?);
}
