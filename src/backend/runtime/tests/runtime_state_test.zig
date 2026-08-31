//! Vertical tests for the runtime-state subscription and delivery projection.

const std = @import("std");
const core = @import("telar-core");
const agent_mod = @import("../../agent/root.zig");
const pane_mod = @import("../../pane/root.zig");
const workspace_mod = @import("../../workspace/root.zig");
const attachment_mod = @import("../attachment/root.zig");
const delivery_mod = @import("../delivery/root.zig");
const runtime_state_controller = @import("../controllers/runtime_state.zig");
const system_metrics_mod = @import("../observability/root.zig").system_metrics;
const telemetry_mod = @import("../observability/root.zig").telemetry;

const schema = core.schema;
const AttachmentStore = attachment_mod.AttachmentStore;
const Delivery = delivery_mod.Delivery;
const RuntimeStateController = runtime_state_controller.Controller(*Delivery);

const RuntimeStateFixture = struct {
    delivery: Delivery,
    attachments: AttachmentStore = .{},
    panes: pane_mod.PaneStore = .{},
    workspaces: workspace_mod.State = .{},
    agents: agent_mod.Tracker = .{},
    system_metrics: system_metrics_mod.Sampler = .{},
    metrics: telemetry_mod.RuntimeMetrics = .{ .started_ns = 0 },

    fn create() !*RuntimeStateFixture {
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

    fn destroy(fixture: *RuntimeStateFixture) void {
        fixture.attachments.deinit();
        fixture.delivery.deinit(std.testing.allocator);
        std.testing.allocator.destroy(fixture);
    }

    fn sources(fixture: *RuntimeStateFixture) delivery_mod.Sources {
        return .{
            .panes = &fixture.panes,
            .workspaces = workspace_mod.Reader.init(&fixture.workspaces),
            .agents = &fixture.agents,
            .system_metrics = &fixture.system_metrics,
            .proxy_active = true,
            .home = null,
        };
    }

    fn next(fixture: *RuntimeStateFixture) !?schema.ServerMessage {
        const prepared = (try fixture.delivery.prepare(.{
            .io = std.testing.io,
            .attachments = &fixture.attachments,
            .sources = fixture.sources(),
            .metrics = &fixture.metrics,
        })) orelse return null;
        const message = try schema.decodeServer(prepared.payload);
        fixture.delivery.commit(.{
            .prepared = prepared,
            .attachments = &fixture.attachments,
            .metrics = &fixture.metrics,
        });
        _ = fixture.delivery.complete({});
        return message;
    }
};

test "runtime-state subscription emits current projections once and future revisions" {
    const fixture = try RuntimeStateFixture.create();
    defer fixture.destroy();

    try std.testing.expect((try fixture.next()) == null);

    var controller = RuntimeStateController.init(&fixture.delivery);
    controller.requestRuntimeState();
    controller.requestRuntimeState();

    const proxy = (try fixture.next()).?;
    switch (proxy) {
        .proxy_status => |status| try std.testing.expect(status.active),
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

    controller.requestRuntimeState();
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
