const OutputObservation = @This();
const terminal_history = @import("terminal.zig");
bytes: []const u8,
shell_foreground: ?bool,
clock: terminal_history.Clock,
