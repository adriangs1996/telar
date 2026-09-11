const max_agent_session_title_bytes_module = @import("telar-core").max_agent_session_title_bytes;
const AgentTitleSourceType = @import("telar-core").AgentTitleSource;
const AgentTitleStateType = @import("telar-core").AgentTitleState;
const Agent = @import("Agent.zig");
const CaptureType = @import("Capture.zig");
const Title = @This();

bytes: [max_agent_session_title_bytes_module]u8 = undefined,
len: u8 = 0,
source: AgentTitleSourceType = .telar,
state: AgentTitleStateType = .placeholder,
phase: Agent.TitlePhase = .waiting_query,
capture: CaptureType = .{},

pub fn slice(title: *const Title) []const u8 {
    return title.bytes[0..title.len];
}

pub fn clearSensitive(title: *Title) void {
    title.capture.clear();
}
