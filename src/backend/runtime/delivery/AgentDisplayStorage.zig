const AgentDisplayStorage = @This();
const source_namespace = @import("root.zig");
const core = @import("telar-core");
workspace: [source_namespace.schema.max_agent_workspace_label_bytes]u8 = undefined,
cwd: [source_namespace.schema.max_agent_cwd_label_bytes]u8 = undefined,
placeholder: [core.agent_manifest.max_placeholder_bytes]u8 = undefined,
