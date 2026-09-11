/// Bounded copy of the child's OSC 0/2 window title. Control bytes are
/// dropped and long titles are cut on a UTF-8 boundary, so every stored
/// value is safe to place in a frame or a host title sequence.
const TitleState = @This();
const source_namespace = @import("root.zig");
const std = @import("std");
bytes: [source_namespace.schema.max_pane_title_bytes]u8 = undefined,
len: u16 = 0,
revision: u64 = 1,

pub fn slice(state: *const TitleState) []const u8 {
    return state.bytes[0..state.len];
}

/// Stores a sanitized copy and reports whether the title changed.
///
/// ```zig
/// if (state.observe(terminal.getTitle() orelse "")) publish();
/// ```
pub fn observe(state: *TitleState, raw: []const u8) bool {
    var candidate: [source_namespace.schema.max_pane_title_bytes]u8 = undefined;
    const len = source_namespace.sanitizeTitle(&candidate, raw);
    if (std.mem.eql(u8, state.slice(), candidate[0..len])) {
        return false;
    }

    @memcpy(state.bytes[0..len], candidate[0..len]);
    state.len = @intCast(len);
    state.revision +%= 1;
    if (state.revision == 0) {
        state.revision = 1;
    }

    return true;
}
