//! Application command for an agent reporting the name its own session
//! carries.

const std = @import("std");
const agent_identity = @import("../coordinators/root.zig").agent_identity;
const core = @import("telar-core");
const agent_mod = @import("../../../agent/root.zig");
const pane_mod = @import("../../../pane/root.zig");

const schema = core.schema;
pub const PaneStore = pane_mod.PaneStore;
pub const Tracker = agent_mod.Tracker;

pub const ReportAgentTitle = @import("ReportAgentTitle.zig");

pub const ReportAgentTitleResult = enum {
    recorded,
    unchanged,
    pane_not_found,
    invalid_title,
};

pub const ReportAgentTitleHandler = @import("ReportAgentTitleHandler.zig");
