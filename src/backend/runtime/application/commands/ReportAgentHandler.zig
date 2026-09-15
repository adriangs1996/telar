const PaneStoreType = @import("../../../pane/PaneStore.zig");
const TrackerType = @import("../../../agent/Tracker.zig");
const ReportAgent = @import("ReportAgent.zig");
const ReportAgentResult = @import("ReportAgentResult.zig");
const SessionReferenceType = @import("../../../agent/SessionReference.zig");
const agent_identity = @import("../coordinators/agent_identity.zig");
const std = @import("std");
const ReportAgentHandler = @This();

panes: *const PaneStoreType,
agents: *TrackerType,

/// Applies the report to the agent of the exact pane generation and
/// returns the projected status before and after, so the caller can
/// publish the audible transition.
///
/// ```zig
/// const result = handler.execute(.{ .pane = key, .state = .working, .session = "", .now_ms = now_ms });
/// ```
pub fn execute(handler: *ReportAgentHandler, command: ReportAgent) ReportAgentResult {
    const pane = handler.panes.resolveConst(command.pane) orelse return .{ .outcome = .pane_not_found };
    if (pane.exit != null) {
        return .{ .outcome = .pane_not_found };
    }
    const session: ?SessionReferenceType = if (command.session.len == 0)
        null
    else
        SessionReferenceType.init(command.session, command.now_ms) catch return .{ .outcome = .invalid_session };
    const identity = agent_identity.fromPane(pane);
    const previous = handler.agents.projectedStatus(identity.key);
    const previous_session = handler.agents.sessionReference(identity.key);

    const changed = handler.agents.observeReport(.{
        .identity = identity,
        .state = command.state,
        .blocked_reason = command.blocked_reason,
        .event = command.event,
        .observed_at_ms = command.now_ms,
        .observed_at_ns = command.now_ns,
        .session = session,
        .session_file = command.session_file,
    });
    const current = handler.agents.projectedStatus(identity.key);
    const current_session = handler.agents.sessionReference(identity.key);

    return .{
        .outcome = if (changed) .applied else .unchanged,
        .previous = previous,
        .current = current,
        .session_recorded = if (current_session) |recorded|
            if (previous_session) |previous_reference| !std.mem.eql(u8, recorded.slice(), previous_reference.slice()) else true
        else
            false,
    };
}

test "lifecycle reports persist every changed session reference and ignore repeats" {
    const PaneFixture = @import("../../tests/PaneFixture.zig");
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStoreType = .{};
    try panes.insert(fixture.pane);
    var handler: ReportAgentHandler = .{ .panes = &panes, .agents = &fixture.agents };
    var command: ReportAgent = .{
        .pane = fixture.pane.key(),
        .state = .ready,
        .session = "0192aaaa-bbbb-cccc-dddd-eeeeffff0000",
        .now_ms = 1_000,
    };

    try std.testing.expect(handler.execute(command).session_recorded);
    command.now_ms += 1;
    try std.testing.expect(!handler.execute(command).session_recorded);
    command.session = "0192aaaa-bbbb-cccc-dddd-eeeeffff0001";
    command.now_ms += 1;
    try std.testing.expect(handler.execute(command).session_recorded);
    try std.testing.expectEqualStrings(command.session, fixture.agents.sessionReference(command.pane).?.slice());

    command.session = "";
    command.now_ms += 1;
    try std.testing.expect(!handler.execute(command).session_recorded);
    command.session = "invalid reference";
    const invalid = handler.execute(command);
    try std.testing.expectEqual(.invalid_session, invalid.outcome);
    try std.testing.expect(!invalid.session_recorded);
}
