const CommandContext = @import("CommandContext.zig");
const CommandType = @import("Command.zig");
const CommandRecord = @This();

context: CommandContext,
command: CommandType,
