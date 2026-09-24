const CommandContext = @import("CommandContext.zig");
const cmdcapture = @import("cmdcapture");
const Command = cmdcapture.Command;
const CommandRecord = @This();

context: CommandContext,
command: Command,
