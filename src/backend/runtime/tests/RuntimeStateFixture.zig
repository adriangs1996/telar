const RuntimeStateFixture = @This();
const source_namespace = @import("runtime_state_test.zig");
const pane_mod = @import("../../pane/root.zig");
const workspace_mod = @import("../../workspace/root.zig");
const agent_mod = @import("../../agent/root.zig");
const system_metrics_mod = @import("../observability/root.zig").system_metrics;
const telemetry_mod = @import("../observability/root.zig").telemetry;
const std = @import("std");
const delivery_mod = @import("../delivery/root.zig");
delivery: source_namespace.Delivery,
attachments: source_namespace.AttachmentStore = .{},
panes: pane_mod.PaneStore = .{},
workspaces: workspace_mod.State = .{},
agents: agent_mod.Tracker = .{},
system_metrics: system_metrics_mod.Sampler = .{},
metrics: telemetry_mod.RuntimeMetrics = .{ .started_ns = 0 },

pub fn create() !*RuntimeStateFixture {
    const fixture = try std.testing.allocator.create(RuntimeStateFixture);
    errdefer std.testing.allocator.destroy(fixture);

    fixture.* = .{
        .delivery = try source_namespace.Delivery.init(std.testing.allocator),
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

pub fn destroy(fixture: *RuntimeStateFixture) void {
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

pub fn next(fixture: *RuntimeStateFixture) !?source_namespace.schema.ServerMessage {
    const prepared = (try fixture.delivery.prepare(.{
        .io = std.testing.io,
        .attachments = &fixture.attachments,
        .sources = fixture.sources(),
        .metrics = &fixture.metrics,
    })) orelse return null;
    const message = try source_namespace.schema.decodeServer(prepared.payload);
    fixture.delivery.commit(.{
        .prepared = prepared,
        .attachments = &fixture.attachments,
        .metrics = &fixture.metrics,
    });
    _ = fixture.delivery.complete({});
    return message;
}
