const core = @import("telar-core");
const Identity = @import("Identity.zig");
const SessionHost = @import("SessionHost.zig").SessionHost;
const ProcessObservation = @This();

identity: Identity,
provider: core.AgentProvider,
process_id: u32,
/// Where the agent's interactive session, and so its hooks, runs.
session_host: SessionHost = .unknown,
/// The group member the agent runs as, which may not be the group's
/// leader, when the probe found it.
agent_pid: ?u32 = null,
/// telar's hooks for the agent are installed.
hooks_installed: bool = false,
observed_at_ms: i64,
