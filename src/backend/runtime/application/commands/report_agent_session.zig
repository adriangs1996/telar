//! Application command for an agent reporting its own session reference.

const std = @import("std");
const core = @import("telar-core");
const agent_mod = @import("../../../agent/root.zig");
const pane_mod = @import("../../../pane/root.zig");

const schema = core.schema;
const PaneStore = pane_mod.PaneStore;
const Tracker = agent_mod.Tracker;

pub const ReportAgentSession = struct {
    pane: pane_mod.PaneKey,
    session: []const u8,
    now_ms: i64,
};

pub const ReportAgentSessionResult = enum {
    recorded,
    unchanged,
    pane_not_found,
    invalid_session,
};

pub const ReportAgentSessionHandler = struct {
    panes: *const PaneStore,
    agents: *Tracker,

    /// Validates the reference and stores it on the agent that owns the exact
    /// pane generation.
    ///
    /// ```zig
    /// const result = handler.execute(.{ .pane = key, .session = "0192...", .now_ms = now_ms });
    /// ```
    pub fn execute(handler: *ReportAgentSessionHandler, command: ReportAgentSession) ReportAgentSessionResult {
        const pane = handler.panes.resolveConst(command.pane) orelse return .pane_not_found;
        if (pane.exit != null) {
            return .pane_not_found;
        }
        const reference = agent_mod.SessionReference.init(command.session, command.now_ms) catch return .invalid_session;
        const identity = agent_mod.Identity.fromPane(pane);

        return if (handler.agents.observeSessionReference(identity, reference)) .recorded else .unchanged;
    }
};
