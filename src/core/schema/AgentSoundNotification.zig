const AgentSoundNotification = @This();
const id = @import("id.zig");
const source_namespace = @import("types.zig");
pane_id: id.PaneId,
pane_generation: u64,
sound: source_namespace.AgentSound,
