const PaneRecord = @This();

pane_id: u64,
workspace_id: u64,
tab_id: u64,
cwd: []const u8,
cols: u16,
rows: u16,
/// NUL-separated launch arguments, `argument_count` of them.
arguments: []const u8,
argument_count: u16,
/// Provider index of the agent that ran here, `0` when none.
agent_provider: u8 = 0,
/// The agent's reported session reference, empty when unknown.
agent_session: []const u8 = "",
/// The session title shown for the agent, empty when it had none worth
/// keeping. `agent_title_source` is the `AgentTitleSource` that made it.
agent_title: []const u8 = "",
agent_title_source: u8 = 0,
