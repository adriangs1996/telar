const Responses = @This();

context: *anyopaque,
write_fn: *const fn (*anyopaque, []const u8) void,

pub fn write(responses: Responses, bytes: []const u8) void {
    responses.write_fn(responses.context, bytes);
}
