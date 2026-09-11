const CwdState = @This();
const source_namespace = @import("root.zig");
const std = @import("std");
bytes: [source_namespace.schema.max_cwd_bytes]u8 = undefined,
len: u16 = 0,
revision: u64 = 1,

pub fn init(path: []const u8) !CwdState {
    var state: CwdState = .{};
    if (!state.set(path)) {
        return error.InvalidCwd;
    }
    return state;
}

pub fn slice(state: *const CwdState) []const u8 {
    return state.bytes[0..state.len];
}

/// Invalid observations and repeated values are ignored. The fixed buffer
/// makes updates allocation-free and keeps every wire value bounded.
///
/// ```zig
/// if (cwd.update(path)) {
///     publishCwd(cwd.slice());
/// }
/// ```
pub fn update(state: *CwdState, path: []const u8) bool {
    if (!validCwd(path) or std.mem.eql(u8, state.slice(), path)) {
        return false;
    }
    @memcpy(state.bytes[0..path.len], path);
    state.len = @intCast(path.len);
    state.revision +%= 1;
    if (state.revision == 0) {
        state.revision = 1;
    }
    return true;
}

fn set(state: *CwdState, path: []const u8) bool {
    if (!validCwd(path)) {
        return false;
    }
    @memcpy(state.bytes[0..path.len], path);
    state.len = @intCast(path.len);
    return true;
}

fn validCwd(path: []const u8) bool {
    return path.len != 0 and path.len <= source_namespace.schema.max_cwd_bytes and
        std.mem.indexOfScalar(u8, path, 0) == null;
}
