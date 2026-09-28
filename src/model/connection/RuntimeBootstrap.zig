//! What a client tells the runtime right after it connects: whether it maps
//! shared-memory graphics, who it is, and its terminal colors. Every session
//! of one client sends the same bootstrap.
const core = @import("telar-core");
const RuntimeBootstrap = @This();

graphics_shared: bool,
client_identity: core.ClientIdentity,
terminal_colors: core.TerminalColors = .{},
