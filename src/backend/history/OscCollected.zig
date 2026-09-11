const Collected = @This();
const Command = @import("Command.zig");
count: usize = 0,
last: ?Command = null,

pub fn emit(self: *Collected, command: Command) void {
    self.count += 1;
    self.last = command;
}
