const Scan = @This();
const core = @import("telar-core");
const vt = @import("ghostty-vt");
provider: core.schema.AgentProvider,
confidence: u8,
ready: *const fn (terminal: *const vt.Terminal) bool,
