const Fixture = @This();
const agent_mod = @import("../../../agent/root.zig");
const State = @import("State.zig");
const Capture = @import("AgentDescriptionCapture.zig");
const source_namespace = @import("agent_description.zig");
agents: agent_mod.Tracker = .{},
state: State = .{},
capture: Capture = .{},

pub fn coordinator(fixture: *Fixture, command: ?source_namespace.description.Command) source_namespace.TestCoordinator {
    fixture.capture.state = &fixture.state;
    return source_namespace.TestCoordinator.init(&fixture.capture, .{
        .agents = &fixture.agents,
        .state = &fixture.state,
        .command = command,
    });
}
