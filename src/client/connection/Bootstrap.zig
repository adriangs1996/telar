const ClientIdentityType = @import("telar-core").ClientIdentity;
const TerminalColorsType = @import("telar-core").TerminalColors;
const Bootstrap = @This();

graphics_shared: bool,
client_identity: ClientIdentityType,
terminal_colors: TerminalColorsType = .{},
