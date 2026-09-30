const PaneRef = @import("PaneRef.zig");
const core = @import("telar-core");
/// The runtime socket, the pane generation a hook reports for and the agent
/// whose hook it is.
const Target = @This();

socket: ?[*:0]const u8,
pane: PaneRef,
provider: core.AgentProvider,
