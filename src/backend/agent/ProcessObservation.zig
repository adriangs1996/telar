const Identity = @import("Identity.zig");
const AgentProviderType = @import("telar-core").AgentProvider;
const ProcessObservation = @This();

identity: Identity,
provider: AgentProviderType,
process_id: u32,
observed_at_ms: i64,
