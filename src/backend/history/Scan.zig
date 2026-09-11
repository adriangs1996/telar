const AgentProviderType = @import("telar-core").AgentProvider;
const vt = @import("ghostty-vt");
const Scan = @This();

provider: AgentProviderType,
confidence: u8,
ready: *const fn (terminal: *const vt.Terminal) bool,
