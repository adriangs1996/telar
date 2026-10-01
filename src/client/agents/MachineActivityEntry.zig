const core = @import("telar-core");
const FleetCard = @import("FleetCard.zig").FleetCard;
const MachineActivityEntry = @This();

source: u8,
agent: ?u8 = null,
/// The owning replica's worktree row, for either an agent task or a command.
worktree: ?u16 = null,
project: ?core.WorkspaceId = null,
card: FleetCard = .agent,
/// Index in the returned presentation order; parents always precede children.
parent: ?u16 = null,
depth: u16 = 0,
coordinator: bool = false,
first_in_project: bool = false,
