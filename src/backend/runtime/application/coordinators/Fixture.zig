const TrackerType = @import("../../../agent/Tracker.zig");
const State = @import("State.zig");
const AgentDescriptionCapture = @import("AgentDescriptionCapture.zig");
const CommandType = @import("../../../agent/Command.zig");
const agent_description = @import("agent_description.zig");
const Fixture = @This();

agents: TrackerType = .{},
state: State = .{},
capture: AgentDescriptionCapture = .{},

pub fn coordinator(fixture: *Fixture, command: ?CommandType) agent_description.TestCoordinator {
    fixture.capture.state = &fixture.state;
    return agent_description.TestCoordinator.init(&fixture.capture, .{
        .agents = &fixture.agents,
        .state = &fixture.state,
        .command = command,
    });
}
