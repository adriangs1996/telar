const PaneFixtureType = @import("PaneFixture.zig");
const PaneStoreType = @import("../../pane/PaneStore.zig");
const SendPaneTextTestScheduleCapture = @import("SendPaneTextTestScheduleCapture.zig");
const ResponseQueueType = @import("../delivery/ResponseQueue.zig");
const SendPaneTextHandlerType = @import("../application/commands/SendPaneTextHandler.zig");
const std = @import("std");
const PaneKeyType = @import("../../pane/PaneKey.zig");
const Harness = @This();

fixture: PaneFixtureType = .{},
panes: PaneStoreType = .{},
capture: SendPaneTextTestScheduleCapture = .{},
responses: ResponseQueueType = .{},

pub fn init(harness: *Harness) !void {
    try harness.fixture.init();
    errdefer harness.fixture.deinit();
    try harness.panes.insert(harness.fixture.pane);
}

pub fn deinit(harness: *Harness) void {
    harness.fixture.deinit();
}

pub fn handler(harness: *Harness) SendPaneTextHandlerType {
    return .{
        .panes = &harness.panes,
        .agents = &harness.fixture.agents,
        .input = .{
            .io = std.testing.io,
            .metrics = &harness.fixture.metrics,
            .agent_input = &harness.fixture.agents,
            .scheduler = harness.capture.scheduler(),
        },
    };
}

pub fn key(harness: *const Harness) PaneKeyType {
    return harness.fixture.pane.key();
}
