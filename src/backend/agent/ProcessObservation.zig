const core = @import("telar-core");
const Identity = @import("Identity.zig");
const ProcessObservation = @This();

identity: Identity,
provider: core.AgentProvider,
process_id: u32,
/// The agent runs its session, and its hooks, in a shared server outside
/// the pane.
shared_server: bool = false,
observed_at_ms: i64,
