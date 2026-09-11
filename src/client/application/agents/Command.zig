const Command = @This();
const agents = @import("../../root.zig").agents;
const source_namespace = @import("agent_sound.zig");
key: agents.AgentKey,
sound: source_namespace.schema.AgentSound,
