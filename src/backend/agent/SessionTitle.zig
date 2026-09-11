const max_agent_session_title_bytes_module = @import("telar-core").max_agent_session_title_bytes;
const AgentTitleSourceType = @import("telar-core").AgentTitleSource;
const validateSessionTitle_module = @import("telar-core").validateSessionTitle;
/// A ready session title with the source that produced it, bounded so the
/// checkpoint can carry it and restore can hand it back to a resumed agent.
const SessionTitle = @This();

bytes: [max_agent_session_title_bytes_module]u8 = undefined,
len: u8 = 0,
source: AgentTitleSourceType,

pub fn slice(title: *const SessionTitle) []const u8 {
    return title.bytes[0..title.len];
}

/// Copies a validated title. Only generated, manual and agent titles are
/// durable; placeholders and a child's own window title are never stored.
///
/// ```zig
/// const title = try SessionTitle.init("Investigate proxy lifecycle", .generated);
/// ```
pub fn init(value: []const u8, source: AgentTitleSourceType) !SessionTitle {
    if (source != .generated and source != .manual and source != .agent) {
        return error.InvalidSessionTitle;
    }

    try validateSessionTitle_module(value);
    var title: SessionTitle = .{ .source = source };
    @memcpy(title.bytes[0..value.len], value);
    title.len = @intCast(value.len);
    return title;
}
