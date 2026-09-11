/// A ready session title with the source that produced it, bounded so the
/// checkpoint can carry it and restore can hand it back to a resumed agent.
const SessionTitle = @This();
const source_namespace = @import("types.zig");
bytes: [source_namespace.schema.max_agent_session_title_bytes]u8 = undefined,
len: u8 = 0,
source: source_namespace.schema.AgentTitleSource,

pub fn slice(title: *const SessionTitle) []const u8 {
    return title.bytes[0..title.len];
}

/// Copies a validated title. Only generated, manual and agent titles are
/// durable; placeholders and a child's own window title are never stored.
///
/// ```zig
/// const title = try SessionTitle.init("Investigate proxy lifecycle", .generated);
/// ```
pub fn init(value: []const u8, source: source_namespace.schema.AgentTitleSource) !SessionTitle {
    if (source != .generated and source != .manual and source != .agent) {
        return error.InvalidSessionTitle;
    }

    try source_namespace.schema.validateSessionTitle(value);
    var title: SessionTitle = .{ .source = source };
    @memcpy(title.bytes[0..value.len], value);
    title.len = @intCast(value.len);
    return title;
}
