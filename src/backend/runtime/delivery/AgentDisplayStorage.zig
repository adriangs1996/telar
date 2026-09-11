const max_agent_workspace_label_bytes_module = @import("telar-core").max_agent_workspace_label_bytes;
const max_agent_cwd_label_bytes_module = @import("telar-core").max_agent_cwd_label_bytes;
const max_agent_session_title_bytes = @import("telar-core").max_agent_session_title_bytes;
const AgentDisplayStorage = @This();

workspace: [max_agent_workspace_label_bytes_module]u8 = undefined,
cwd: [max_agent_cwd_label_bytes_module]u8 = undefined,
placeholder: [max_agent_session_title_bytes]u8 = undefined,
