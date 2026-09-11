const Collected = @This();
const source_namespace = @import("terminal.zig");
bytes: [256]u8 = undefined,
len: usize = 0,
cwd: [256]u8 = undefined,
cwd_len: usize = 0,
exit_code: ?i32 = null,

pub fn emit(collected: *Collected, command: source_namespace.Command) void {
    collected.len = @min(command.bytes.len, collected.bytes.len);
    @memcpy(collected.bytes[0..collected.len], command.bytes[0..collected.len]);
    collected.cwd_len = @min(command.cwd.len, collected.cwd.len);
    @memcpy(collected.cwd[0..collected.cwd_len], command.cwd[0..collected.cwd_len]);
    collected.exit_code = command.exit_code;
}
