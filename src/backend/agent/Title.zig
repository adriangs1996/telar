const Title = @This();
const source_namespace = @import("Agent.zig");
const description = @import("description.zig");
bytes: [source_namespace.schema.max_agent_session_title_bytes]u8 = undefined,
len: u8 = 0,
source: source_namespace.schema.AgentTitleSource = .telar,
state: source_namespace.schema.AgentTitleState = .placeholder,
phase: source_namespace.TitlePhase = .waiting_query,
capture: description.Capture = .{},

pub fn slice(title: *const Title) []const u8 {
    return title.bytes[0..title.len];
}

pub fn clearSensitive(title: *Title) void {
    title.capture.clear();
}
