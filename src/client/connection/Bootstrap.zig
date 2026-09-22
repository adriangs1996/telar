const core = @import("telar-core");
const Bootstrap = @This();

graphics_shared: bool,
client_identity: core.ClientIdentity,
terminal_colors: core.TerminalColors = .{},
