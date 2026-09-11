const Bootstrap = @This();
const source_namespace = @import("runtime_transport.zig");
graphics_shared: bool,
client_identity: source_namespace.schema.ClientIdentity,
terminal_colors: source_namespace.schema.TerminalColors = .{},
