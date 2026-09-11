//! Application command for an official lifecycle report from an agent's
//! hooks.

const std = @import("std");
const agent_identity = @import("../coordinators/root.zig").agent_identity;
const core = @import("telar-core");
const agent_mod = @import("../../../agent/root.zig");
const pane_mod = @import("../../../pane/root.zig");

pub const schema = core.schema;
pub const PaneStore = pane_mod.PaneStore;
pub const Tracker = agent_mod.Tracker;

pub const ReportAgent = @import("ReportAgent.zig");

pub const ReportAgentResult = @import("ReportAgentResult.zig");

pub const ReportAgentHandler = @import("ReportAgentHandler.zig");
