const core = @import("telar-core");

// SAFETY: agent_snapshot formats or copies the workspace label before exposing the returned prefix in an entry.
workspace: [core.max_agent_workspace_label_bytes]u8 = undefined,
// SAFETY: agent_snapshot shortens the cwd into this output buffer before exposing the returned prefix in an entry.
cwd: [core.max_agent_cwd_label_bytes]u8 = undefined,
// SAFETY: agent_snapshot generates the placeholder here when needed; entries retain only the formatter result.
placeholder: [core.max_agent_session_title_bytes]u8 = undefined,
