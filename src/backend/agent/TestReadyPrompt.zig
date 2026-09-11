const TestReadyPrompt = @This();
const source_namespace = @import("tracker_support.zig");
provider: source_namespace.schema.AgentProvider,
observed_at_ms: i64,
