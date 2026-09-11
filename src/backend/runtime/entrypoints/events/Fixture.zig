const Fixture = @This();
const test_support = @import("../../tests/support.zig");
const source_namespace = @import("proxy_observation.zig");
const Capture = @import("ProxyObservationCapture.zig");
const proxy_mod = @import("../../../proxy/root.zig");
support: test_support.PaneFixture = .{},
panes: source_namespace.PaneStore = .{},
capture: Capture = .{},

pub fn init(fixture: *Fixture) !void {
    try fixture.support.init();
    errdefer fixture.support.deinit();
    try fixture.panes.insert(fixture.support.pane);
    fixture.capture.agents = &fixture.support.agents;
    fixture.capture.pane = fixture.support.pane.key();
}

pub fn deinit(fixture: *Fixture) void {
    fixture.support.deinit();
}

pub fn adapter(fixture: *Fixture) source_namespace.TestAdapter {
    return source_namespace.TestAdapter.init(&fixture.capture, .{
        .panes = &fixture.panes,
        .agents = &fixture.support.agents,
        .metrics = &fixture.support.metrics,
    });
}

pub fn event(fixture: *const Fixture, phase: proxy_mod.ObservationPhase, protocol: proxy_mod.ObservationProtocol) proxy_mod.Observation {
    return source_namespace.eventFor(fixture.support.pane, phase, protocol);
}
