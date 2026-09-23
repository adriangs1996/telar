const Responses = @This();

context: *anyopaque,
write_fn: *const fn (*anyopaque, []const u8) void,

pub fn write(self: Responses, bytes: []const u8) void {
    self.write_fn(self.context, bytes);
}
