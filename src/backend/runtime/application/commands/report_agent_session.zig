//! Application command for an agent reporting its own session reference.

const std = @import("std");
const agent_identity = @import("../coordinators/root.zig").agent_identity;
const core = @import("telar-core");
const agent_mod = @import("../../../agent/root.zig");
const pane_mod = @import("../../../pane/root.zig");

const schema = core.schema;
pub const PaneStore = pane_mod.PaneStore;
pub const Tracker = agent_mod.Tracker;

pub const ReportAgentSession = @import("ReportAgentSession.zig");

pub const ReportAgentSessionResult = enum {
    recorded,
    unchanged,
    pane_not_found,
    invalid_session,
};

pub const ReportAgentSessionHandler = @import("ReportAgentSessionHandler.zig");
