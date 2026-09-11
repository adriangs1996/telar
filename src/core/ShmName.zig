/// A validated POSIX shared memory object name crossing the runtime-client
/// boundary. The allowlist is exactly what Telar generates: a leading slash
/// followed by lowercase hex and dashes. Anything else is rejected before a
/// process calls `shm_open` with it.
const ShmName = @This();
const source_namespace = @import("graphics.zig");
bytes: [source_namespace.max_shm_name_bytes + 1]u8 = undefined,
len: u8 = 0,

pub fn init(name: []const u8) error{InvalidShmName}!ShmName {
    if (name.len < 2 or name.len > source_namespace.max_shm_name_bytes) {
        return error.InvalidShmName;
    }
    if (name[0] != '/') {
        return error.InvalidShmName;
    }
    for (name[1..]) |byte| switch (byte) {
        'a'...'z', '0'...'9', '-' => {},
        else => return error.InvalidShmName,
    };
    var value: ShmName = .{ .len = @intCast(name.len) };
    @memcpy(value.bytes[0..name.len], name);
    value.bytes[name.len] = 0;
    return value;
}

pub fn slice(name: *const ShmName) []const u8 {
    return name.bytes[0..name.len];
}

pub fn sliceZ(name: *const ShmName) [:0]const u8 {
    return name.bytes[0..name.len :0];
}
