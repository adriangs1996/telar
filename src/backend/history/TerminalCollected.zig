const Command = @import("Command.zig");
const Collected = @This();

bytes: [256]u8 = undefined,
len: usize = 0,
cwd: [256]u8 = undefined,
cwd_len: usize = 0,
exit_code: ?i32 = null,

pub fn emit(self: *Collected, command: Command) void {
    self.len = @min(command.bytes.len, self.bytes.len);
    @memcpy(self.bytes[0..self.len], command.bytes[0..self.len]);
    self.cwd_len = @min(command.cwd.len, self.cwd.len);
    @memcpy(self.cwd[0..self.cwd_len], command.cwd[0..self.cwd_len]);
    self.exit_code = command.exit_code;
}
