const PaneKeyType = @import("../pane/PaneKey.zig");
const SessionReferenceType = @import("SessionReference.zig");
const AgentSessionFileKind = @import("telar-core").AgentSessionFileKind;
const max_agent_session_file_bytes = @import("telar-core").max_agent_session_file_bytes;
const max_agent_session_title_bytes_module = @import("telar-core").max_agent_session_title_bytes;
const std = @import("std");
/// One agent's session file and the probe state that belongs to it.
const Watch = @This();

key: PaneKeyType,
session: SessionReferenceType,
kind: AgentSessionFileKind,
path: [max_agent_session_file_bytes]u8 = undefined,
path_len: u16 = 0,
/// Transcript scan position. Null until the first probe seeds it at the
/// end of the file, so only names given after the watch began are read.
offset: ?u64 = null,
/// The last name handed to the agent, so a state database read every
/// second reports only changes.
name: [max_agent_session_title_bytes_module]u8 = undefined,
name_len: u8 = 0,
name_known: bool = false,
checked_at_ms: i64 = 0,
pending: bool = false,

pub fn pathSlice(watch: *const Watch) []const u8 {
    return watch.path[0..watch.path_len];
}

pub fn nameSlice(watch: *const Watch) []const u8 {
    return watch.name[0..watch.name_len];
}

/// Records a name as handed over and reports whether it differs from the
/// previous one.
///
/// ```zig
/// if (watch.remember(title)) apply(title);
/// ```
pub fn remember(watch: *Watch, value: []const u8) bool {
    if (watch.name_known and std.mem.eql(u8, watch.nameSlice(), value)) {
        return false;
    }

    @memcpy(watch.name[0..value.len], value);
    watch.name_len = @intCast(value.len);
    watch.name_known = true;
    return true;
}
