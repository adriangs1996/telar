//! Vertical tests for the runtime-state subscription and delivery projection.

const GenericRuntimeStateController = @import("../entrypoints/requests/GenericRuntimeStateController.zig").Type;
const Delivery = @import("../delivery/Delivery.zig");
const RuntimeStateFixture = @import("RuntimeStateFixture.zig");
const std = @import("std");
const ProxyScopeType = @import("telar-core").ProxyScope;
const PaneFixture = @import("PaneFixture.zig");

const RuntimeStateController = GenericRuntimeStateController(*Delivery);

test "runtime-state subscription emits current projections once and future revisions" {
    const fixture = try RuntimeStateFixture.create();
    defer fixture.destroy();

    try std.testing.expect((try fixture.next()) == null);

    var controller = RuntimeStateController.init(&fixture.delivery);
    try controller.requestRuntimeState(@enumFromInt(7));
    try controller.requestRuntimeState(@enumFromInt(7));

    const layout = (try fixture.next()).?;
    switch (layout) {
        .client_layout_snapshot => |snapshot| try std.testing.expect(!snapshot.restored),
        else => return error.ExpectedClientLayoutSnapshot,
    }

    const proxy = (try fixture.next()).?;
    switch (proxy) {
        .proxy_status => |status| {
            try std.testing.expect(status.active);
            try std.testing.expectEqual(ProxyScopeType.exact, status.scope);
            try std.testing.expect(!status.system_trusted);
        },
        else => return error.ExpectedProxyStatus,
    }

    const agents = (try fixture.next()).?;
    switch (agents) {
        .agent_snapshot => |snapshot| {
            try std.testing.expectEqual(@as(u64, 1), snapshot.revision);
            try std.testing.expectEqual(@as(u16, 0), snapshot.entry_count);
        },
        else => return error.ExpectedAgentSnapshot,
    }

    const metrics = (try fixture.next()).?;
    switch (metrics) {
        .system_metrics => |values| {
            try std.testing.expectEqual(@as(u64, 7), values.revision);
            try std.testing.expectEqual(@as(u8, 23), values.cpu_percent);
            try std.testing.expectEqual(@as(u16, 41), values.memory_used_decigib);
            try std.testing.expect(values.has_battery);
            try std.testing.expectEqual(@as(u8, 88), values.battery_percent);
        },
        else => return error.ExpectedSystemMetrics,
    }

    const workspaces = (try fixture.next()).?;
    switch (workspaces) {
        .workspace_list => |list| {
            try std.testing.expectEqual(@as(u64, 1), list.revision);
            try std.testing.expectEqual(@as(u16, 0), list.entry_count);
        },
        else => return error.ExpectedWorkspaceList,
    }

    try std.testing.expect((try fixture.next()) == null);

    try controller.requestRuntimeState(@enumFromInt(7));
    try std.testing.expect((try fixture.next()) == null);

    fixture.agents.touch();
    const changed = (try fixture.next()).?;
    switch (changed) {
        .agent_snapshot => |snapshot| {
            try std.testing.expectEqual(@as(u64, 2), snapshot.revision);
            try std.testing.expectEqual(@as(u16, 0), snapshot.entry_count);
        },
        else => return error.ExpectedAgentSnapshot,
    }
    try std.testing.expect((try fixture.next()) == null);
}

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
