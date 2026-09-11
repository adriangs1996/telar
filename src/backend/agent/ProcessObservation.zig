const ProcessObservation = @This();
const Identity = @import("Identity.zig");
const source_namespace = @import("types.zig");
identity: Identity,
provider: source_namespace.schema.AgentProvider,
process_id: u32,
observed_at_ms: i64,
