const Harness = @This();
const source_namespace = @import("send_pane_text_test.zig");
const pane_mod = @import("../../pane/root.zig");
const ScheduleCapture = @import("SendPaneTextTestScheduleCapture.zig");
const delivery_mod = @import("../delivery/root.zig");
const send_pane_text_commands = @import("../application/commands/send_pane_text.zig");
const std = @import("std");
fixture: source_namespace.PaneFixture = .{},
panes: pane_mod.PaneStore = .{},
capture: ScheduleCapture = .{},
responses: delivery_mod.ResponseQueue = .{},

pub fn init(harness: *Harness) !void {
    try harness.fixture.init();
    errdefer harness.fixture.deinit();
    try harness.panes.insert(harness.fixture.pane);
}

pub fn deinit(harness: *Harness) void {
    harness.fixture.deinit();
}

pub fn handler(harness: *Harness) send_pane_text_commands.SendPaneTextHandler {
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

pub fn key(harness: *const Harness) pane_mod.PaneKey {
    return harness.fixture.pane.key();
}
