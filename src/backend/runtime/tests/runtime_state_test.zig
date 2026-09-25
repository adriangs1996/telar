//! Vertical tests for the runtime-state subscription and delivery projection.

const core = @import("telar-core");
const Delivery = @import("../delivery/Delivery.zig");
const Attachments = @import("../attachment/Attachments.zig");
const PaneStore = @import("../../pane/PaneStore.zig");
const Agents = @import("../../agent/Agents.zig");
const hostmetrics = @import("hostmetrics");
const Sampler = hostmetrics.Sampler;
const RuntimeMetrics = @import("../observability/RuntimeMetrics.zig");
const Sources = @import("../delivery/Sources.zig");
const Workspaces = @import("../../workspace/Workspaces.zig");
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
    try std.testing.expect(fixture.attachments.find(RuntimeStateFixture.client, panes.pane.id) == null);

    panes.pane.agent_process_cache.setName("less");
    panes.pane.foreground_revision += 1;
    panes.pane.agent_process_cache.setName("git");
    panes.pane.foreground_revision += 1;
    const latest = (try fixture.next()).?.pane_foreground;
    try std.testing.expectEqualStrings("git", latest.name);
    try std.testing.expect((try fixture.next()) == null);

    _ = try fixture.attachments.add(std.testing.allocator, RuntimeStateFixture.client, panes.pane);
    foreground_received = false;
    while (try fixture.next()) |message| {
        if (message == .pane_foreground) {
            try std.testing.expect(!foreground_received);
            foreground_received = true;
            try std.testing.expectEqualStrings("git", message.pane_foreground.name);
        }
    }
    try std.testing.expect(foreground_received);
    fixture.attachments.deinit(std.testing.allocator);

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

const RuntimeStateFixture = struct {
    /// The fixture client's row in `attachments`. The pane fixture already
    /// attaches client 0 through its own table, and `Pane.observers` has one
    /// bit per client, so this delivery must be another client.
    const client = 1;

    delivery: Delivery,
    attachments: Attachments = .{},
    panes: PaneStore = .{},
    workspaces: Workspaces = .{},
    agents: Agents = .{},
    system_metrics: Sampler = .{},
    metrics: RuntimeMetrics = .{ .started_ns = 0 },

    pub fn create() !*RuntimeStateFixture {
        const fixture = try std.testing.allocator.create(RuntimeStateFixture);
        errdefer std.testing.allocator.destroy(fixture);

        fixture.* = .{
            .delivery = try Delivery.init(std.testing.allocator),
        };
        fixture.system_metrics = .{
            .revision = 7,
            .latest = .{
                .cpu_percent = 23,
                .memory_used_decigib = 41,
                .battery_percent = 88,
            },
        };
        return fixture;
    }

    pub fn destroy(self: *RuntimeStateFixture) void {
        self.attachments.deinit(std.testing.allocator);
        self.delivery.deinit(std.testing.allocator);
        std.testing.allocator.destroy(self);
    }

    fn sources(self: *RuntimeStateFixture) Sources {
        return .{
            .panes = &self.panes,
            .workspaces = &self.workspaces,
            .agents = &self.agents,
            .system_metrics = &self.system_metrics,
            .proxy_active = true,
            .home = null,
        };
    }

    pub fn next(self: *RuntimeStateFixture) !?core.ServerMessage {
        const prepared = (try self.delivery.prepare(.{
            .io = std.testing.io,
            .attachments = &self.attachments,
            .client = client,
            .sources = self.sources(),
            .metrics = &self.metrics,
        })) orelse return null;
        const message = try core.decodeServer(prepared.payload);
        self.delivery.commit(.{
            .prepared = prepared,
            .attachments = &self.attachments,
            .client = client,
            .metrics = &self.metrics,
        });
        _ = self.delivery.complete({});
        return message;
    }
};
