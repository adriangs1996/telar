const core = @import("telar-core");
const Identity = @import("Identity.zig");
const ProcessObservation = @This();

identity: Identity,
provider: core.AgentProvider,
process_id: u32,
observed_at_ms: i64,
