const core = @import("telar-core");
const Identity = @import("Identity.zig");
const SessionHost = @import("SessionHost.zig").SessionHost;
const ProcessObservation = @This();

identity: Identity,
provider: core.AgentProvider,
process_id: u32,
/// Where the agent's interactive session, and so its hooks, runs.
session_host: SessionHost = .unknown,
observed_at_ms: i64,
