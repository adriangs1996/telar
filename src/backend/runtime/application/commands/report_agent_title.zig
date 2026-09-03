//! Application command for an agent reporting the name its own session
//! carries.

const std = @import("std");
const core = @import("telar-core");
const agent_mod = @import("../../../agent/root.zig");
const pane_mod = @import("../../../pane/root.zig");

const schema = core.schema;
const PaneStore = pane_mod.PaneStore;
const Tracker = agent_mod.Tracker;

pub const ReportAgentTitle = struct {
    pane: pane_mod.PaneKey,
    /// Empty clears an earlier agent title.
    title: []const u8,
};

pub const ReportAgentTitleResult = enum {
    recorded,
    unchanged,
    pane_not_found,
    invalid_title,
};

pub const ReportAgentTitleHandler = struct {
    panes: *const PaneStore,
    agents: *Tracker,

    /// Applies the title to the agent that owns the exact pane generation.
    ///
    /// ```zig
    /// const result = handler.execute(.{ .pane = key, .title = "Fix proxy" });
    /// ```
    pub fn execute(handler: *ReportAgentTitleHandler, command: ReportAgentTitle) ReportAgentTitleResult {
        const pane = handler.panes.resolveConst(command.pane) orelse return .pane_not_found;
        if (pane.exit != null) {
            return .pane_not_found;
        }

        const identity = agent_mod.Identity.fromPane(pane);
        const changed = handler.agents.reportTitle(identity, command.title) catch return .invalid_title;

        return if (changed) .recorded else .unchanged;
    }
};
