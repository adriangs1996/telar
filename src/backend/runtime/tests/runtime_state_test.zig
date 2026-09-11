//! Vertical tests for the runtime-state subscription and delivery projection.

const std = @import("std");
const core = @import("telar-core");
const agent_mod = @import("../../agent/root.zig");
const pane_mod = @import("../../pane/root.zig");
const workspace_mod = @import("../../workspace/root.zig");
const attachment_mod = @import("../attachment/root.zig");
const delivery_mod = @import("../delivery/root.zig");
const runtime_state_controller = @import("../entrypoints/requests/runtime_state.zig");
const system_metrics_mod = @import("../observability/root.zig").system_metrics;
const telemetry_mod = @import("../observability/root.zig").telemetry;

pub const schema = core.schema;
pub const AttachmentStore = attachment_mod.AttachmentStore;
pub const Delivery = delivery_mod.Delivery;
const RuntimeStateController = runtime_state_controller.Controller(*Delivery);

const RuntimeStateFixture = @import("RuntimeStateFixture.zig");

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
            try std.testing.expectEqual(schema.ProxyScope.exact, status.scope);
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
