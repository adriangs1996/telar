const core = @import("telar-core");
const AgentDisplayStorage = @This();

workspace: [core.max_agent_workspace_label_bytes]u8 = undefined,
cwd: [core.max_agent_cwd_label_bytes]u8 = undefined,
placeholder: [core.max_agent_session_title_bytes]u8 = undefined,
