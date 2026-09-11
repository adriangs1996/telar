const PrefixWriter = @This();
const source_namespace = @import("host_output.zig");
writer: *source_namespace.Io.Writer,
limit: usize,

pub fn write(context: *anyopaque, bytes: []const u8) !usize {
    const prefix: *PrefixWriter = @ptrCast(@alignCast(context));
    const count = @min(prefix.limit, bytes.len);
    try prefix.writer.writeAll(bytes[0..count]);
    return count;
}
