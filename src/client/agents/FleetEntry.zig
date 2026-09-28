const core = @import("telar-core");
const FleetCard = @import("FleetCard.zig").FleetCard;
/// One agent in fleet order: its index in the agent replica, how it is drawn
/// and the project it is grouped under.
const FleetEntry = @This();

index: u8,
card: FleetCard,
/// The project heading the group; null when the agent's workspace is not
/// in the workspace list.
project: ?core.WorkspaceId,
/// Whether this entry opens a new project group.
first_in_project: bool = false,
