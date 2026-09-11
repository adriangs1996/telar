//! Protocol controller for shell commands reported by official agent hooks.

const core = @import("telar-core");
const delivery_mod = @import("../../delivery/root.zig");
const report_commands = @import("../../application/commands/report_agent_command.zig");

pub const schema = core.schema;
pub const ResponseQueue = delivery_mod.ResponseQueue;

pub const Controller = @import("GenericReportAgentCommandController.zig").Type;
