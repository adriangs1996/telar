const id = @import("id.zig");
const types = @import("types.zig");
const AgentSoundNotification = @This();

pane_id: id.PaneId,
pane_generation: u64,
sound: types.AgentSound,
