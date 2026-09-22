const core = @import("telar-core");
const vt = @import("ghostty-vt");
const Scan = @This();

provider: core.AgentProvider,
confidence: u8,
ready: *const fn (terminal: *const vt.Terminal) bool,
