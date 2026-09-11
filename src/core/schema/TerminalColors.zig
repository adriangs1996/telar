/// Host defaults used for terminal queries, independently of cell styling.
/// Example: `const colors: TerminalColors = .{ .background = .{ 16, 16, 16 } };`.
const TerminalColors = @This();

foreground: ?[3]u8 = null,
background: ?[3]u8 = null,
