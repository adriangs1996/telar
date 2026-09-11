const PaneFixtureType = @import("../../tests/PaneFixture.zig");
const PaneStoreType = @import("../../../pane/PaneStore.zig");
const ProxyObservationCapture = @import("ProxyObservationCapture.zig");
const proxy_observation = @import("proxy_observation.zig");
const middleware = @import("../../../proxy/middleware.zig");
const ObservationType = @import("../../../proxy/Observation.zig");
const Fixture = @This();

support: PaneFixtureType = .{},
panes: PaneStoreType = .{},
capture: ProxyObservationCapture = .{},

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

pub fn adapter(fixture: *Fixture) proxy_observation.TestAdapter {
    return proxy_observation.TestAdapter.init(&fixture.capture, .{
        .panes = &fixture.panes,
        .agents = &fixture.support.agents,
        .metrics = &fixture.support.metrics,
    });
}

pub fn event(fixture: *const Fixture, phase: middleware.Phase, protocol: middleware.Protocol) ObservationType {
    return proxy_observation.eventFor(fixture.support.pane, phase, protocol);
}
