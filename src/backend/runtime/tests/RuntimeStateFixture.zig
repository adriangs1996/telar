const core = @import("telar-core");
const Delivery = @import("../delivery/Delivery.zig");
const AttachmentStore = @import("../attachment/AttachmentStore.zig");
const PaneStore = @import("../../pane/PaneStore.zig");
const Tracker = @import("../../agent/Tracker.zig");
const Sampler = @import("../observability/Sampler.zig");
const RuntimeMetrics = @import("../observability/RuntimeMetrics.zig");
const std = @import("std");
const Sources = @import("../delivery/Sources.zig");
const Workspaces = @import("../../workspace/Workspaces.zig");
const RuntimeStateFixture = @This();

delivery: Delivery,
attachments: AttachmentStore = .{},
panes: PaneStore = .{},
workspaces: Workspaces = .{},
agents: Tracker = .{},
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

pub fn destroy(fixture: *RuntimeStateFixture) void {
    fixture.attachments.deinit();
    fixture.delivery.deinit(std.testing.allocator);
    std.testing.allocator.destroy(fixture);
}

fn sources(fixture: *RuntimeStateFixture) Sources {
    return .{
        .panes = &fixture.panes,
        .workspaces = &fixture.workspaces,
        .agents = &fixture.agents,
        .system_metrics = &fixture.system_metrics,
        .proxy_active = true,
        .home = null,
    };
}

pub fn next(fixture: *RuntimeStateFixture) !?core.ServerMessage {
    const prepared = (try fixture.delivery.prepare(.{
        .io = std.testing.io,
        .attachments = &fixture.attachments,
        .sources = fixture.sources(),
        .metrics = &fixture.metrics,
    })) orelse return null;
    const message = try core.decodeServer(prepared.payload);
    fixture.delivery.commit(.{
        .prepared = prepared,
        .attachments = &fixture.attachments,
        .metrics = &fixture.metrics,
    });
    _ = fixture.delivery.complete({});
    return message;
}
