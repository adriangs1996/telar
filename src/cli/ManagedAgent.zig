const core = @import("telar-core");
const Session = @import("Session.zig");
const PaneRef = @import("PaneRef.zig");
const ManagedAgent = @This();

session: *Session,
pane: PaneRef,

/// Interrupts exactly the resolved pane generation. Example: `try managed.interrupt();`
pub fn interrupt(self: *ManagedAgent) !void {
    const response = try self.session.exchange(core.encodeAgentInterrupt, core.AgentInterrupt{
        .request_id = .none,
        .pane_id = try core.pane(self.pane.pane_id),
        .pane_generation = self.pane.pane_generation,
    });
    if (response != .request_completed) {
        return error.UnexpectedRuntimeResponse;
    }
}

/// Copies one bounded, generation-checked conversation snapshot. Example: `try managed.read(snapshot);`
pub fn read(self: *ManagedAgent, snapshot: *core.AgentThreadSnapshot) !void {
    const pane_id = try core.pane(self.pane.pane_id);
    const accepted = try self.session.exchange(core.encodeQueryAgentThread, core.QueryAgentThread{
        .request_id = .none,
        .pane_id = pane_id,
        .pane_generation = self.pane.pane_generation,
    });
    if (accepted != .request_completed) {
        return error.UnexpectedRuntimeResponse;
    }

    while (true) {
        const response = try self.session.receive();
        if (response != .agent_thread_snapshot) {
            continue;
        }

        const view = response.agent_thread_snapshot;
        if (view.pane_id != pane_id or view.pane_generation != self.pane.pane_generation) {
            return error.UnexpectedRuntimeResponse;
        }

        try view.copyTo(snapshot);
        return;
    }
}

/// Answers one explicit approval, never an implicit current request. Example: `try managed.decide(.{ .id = 42, .accepted = true });`
pub fn decide(self: *ManagedAgent, decision: core.AgentApprovalDecision) !void {
    const response = try self.session.exchange(core.encodeAgentApproval, core.AgentApproval{
        .request_id = .none,
        .pane_id = try core.pane(self.pane.pane_id),
        .pane_generation = self.pane.pane_generation,
        .approval_id = decision.id,
        .accept = decision.accepted,
    });
    if (response != .request_completed) {
        return error.UnexpectedRuntimeResponse;
    }
}
