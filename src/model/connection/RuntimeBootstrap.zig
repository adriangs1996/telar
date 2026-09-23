//! What a client tells the runtime right after host negotiation.
const core = @import("telar-core");
const RuntimeBootstrap = @This();

graphics_shared: bool,
client_identity: core.ClientIdentity,
terminal_colors: core.TerminalColors = .{},
