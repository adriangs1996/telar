const Input = @This();
const terminal_history = @import("terminal.zig");
offset: u32,
len: u32,
shell_foreground: bool,
clock: terminal_history.Clock,
