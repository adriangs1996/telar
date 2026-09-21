//! Vertical tests for the runtime-state subscription and delivery projection.

const RuntimeStateFixture = @import("RuntimeStateFixture.zig");
const std = @import("std");
const PaneFixture = @import("PaneFixture.zig");

test "runtime-state foreground updates reach panes without cell attachments" {
    var panes: PaneFixture = .{};
    try panes.init();
    defer panes.deinit();
    const fixture = try RuntimeStateFixture.create();
    defer fixture.destroy();
    try fixture.panes.insert(panes.pane);
    panes.pane.agent_process_cache.setName("vim");

    try std.testing.expect((try fixture.next()) == null);
    try fixture.delivery.requestRuntimeState(@enumFromInt(7));
    var foreground_received = false;
    while (try fixture.next()) |message| {
        if (message == .pane_foreground) {
            try std.testing.expect(!foreground_received);
            foreground_received = true;
            try std.testing.expectEqual(panes.pane.id, message.pane_foreground.pane_id);
            try std.testing.expectEqualStrings("vim", message.pane_foreground.name);
        }
    }
    try std.testing.expect(foreground_received);
    try std.testing.expect(fixture.attachments.find(panes.pane.id) == null);

    panes.pane.agent_process_cache.setName("less");
    panes.pane.foreground_revision += 1;
    panes.pane.agent_process_cache.setName("git");
    panes.pane.foreground_revision += 1;
    const latest = (try fixture.next()).?.pane_foreground;
    try std.testing.expectEqualStrings("git", latest.name);
    try std.testing.expect((try fixture.next()) == null);

    _ = try fixture.attachments.attach(std.testing.allocator, panes.pane);
    foreground_received = false;
    while (try fixture.next()) |message| {
        if (message == .pane_foreground) {
            try std.testing.expect(!foreground_received);
            foreground_received = true;
            try std.testing.expectEqualStrings("git", message.pane_foreground.name);
        }
    }
    try std.testing.expect(foreground_received);
    fixture.attachments.deinit();

    const replacement = try panes.createPane(@enumFromInt(8));
    defer {
        replacement.session.shutdown();
        replacement.destroy();
    }
    replacement.agent_process_cache.setName("zsh");
    replacement.foreground_revision = panes.pane.foreground_revision;
    fixture.panes = .{};
    try fixture.panes.insert(replacement);
    const reused = (try fixture.next()).?.pane_foreground;
    try std.testing.expectEqual(replacement.id, reused.pane_id);
    try std.testing.expectEqualStrings("zsh", reused.name);
    try std.testing.expect((try fixture.next()) == null);
}
