const CommandRecord = @This();
const CommandContext = @import("CommandContext.zig");
const terminal = @import("terminal.zig");
context: CommandContext,
command: terminal.Command,
