const HeadSink = @This();

context: *anyopaque,
append_fn: *const fn (*anyopaque, []const u8) void,

pub fn append(sink: HeadSink, bytes: []const u8) void {
    sink.append_fn(sink.context, bytes);
}
