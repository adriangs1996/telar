//! Application command for shell-tool reports emitted by official agent hooks.

const std = @import("std");
const core = @import("telar-core");
const pane_mod = @import("../../../pane/root.zig");

pub const schema = core.schema;

pub const ReportAgentCommand = @import("ReportAgentCommand.zig");

pub const Outcome = enum { applied, pane_not_found, queue_full };

pub const ReportAgentCommandHandler = @import("ReportAgentCommandHandler.zig");
