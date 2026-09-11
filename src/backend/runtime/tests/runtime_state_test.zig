//! Vertical tests for the runtime-state subscription and delivery projection.

const GenericRuntimeStateController = @import("../entrypoints/requests/GenericRuntimeStateController.zig").Type;
const Delivery = @import("../delivery/Delivery.zig");
const RuntimeStateFixture = @import("RuntimeStateFixture.zig");
const std = @import("std");
const ProxyScopeType = @import("telar-core").ProxyScope;

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
