const DeliveryType = @import("../delivery/Delivery.zig");
const AttachmentStoreType = @import("../attachment/AttachmentStore.zig");
const PaneStoreType = @import("../../pane/PaneStore.zig");
const StateType = @import("../../workspace/State.zig");
const TrackerType = @import("../../agent/Tracker.zig");
const SamplerType = @import("../observability/Sampler.zig");
const RuntimeMetricsType = @import("../observability/RuntimeMetrics.zig");
const std = @import("std");
const SourcesType = @import("../delivery/Sources.zig");
const ReaderType = @import("../../workspace/Reader.zig");
const ServerMessageType = @import("telar-core").ServerMessage;
const decodeServer_module = @import("telar-core").decodeServer;
const RuntimeStateFixture = @This();

delivery: DeliveryType,
attachments: AttachmentStoreType = .{},
panes: PaneStoreType = .{},
workspaces: StateType = .{},
agents: TrackerType = .{},
system_metrics: SamplerType = .{},
metrics: RuntimeMetricsType = .{ .started_ns = 0 },

pub fn create() !*RuntimeStateFixture {
    const fixture = try std.testing.allocator.create(RuntimeStateFixture);
    errdefer std.testing.allocator.destroy(fixture);

    fixture.* = .{
        .delivery = try DeliveryType.init(std.testing.allocator),
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

fn sources(fixture: *RuntimeStateFixture) SourcesType {
    return .{
        .panes = &fixture.panes,
        .workspaces = ReaderType.init(&fixture.workspaces),
        .agents = &fixture.agents,
        .system_metrics = &fixture.system_metrics,
        .proxy_active = true,
        .home = null,
    };
}

pub fn next(fixture: *RuntimeStateFixture) !?ServerMessageType {
    const prepared = (try fixture.delivery.prepare(.{
        .io = std.testing.io,
        .attachments = &fixture.attachments,
        .sources = fixture.sources(),
        .metrics = &fixture.metrics,
    })) orelse return null;
    const message = try decodeServer_module(prepared.payload);
    fixture.delivery.commit(.{
        .prepared = prepared,
        .attachments = &fixture.attachments,
        .metrics = &fixture.metrics,
    });
    _ = fixture.delivery.complete({});
    return message;
}
