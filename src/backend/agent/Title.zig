const core = @import("telar-core");
const Agent = @import("Agent.zig");
const CaptureType = @import("Capture.zig");
const Title = @This();

bytes: [core.max_agent_session_title_bytes]u8 = undefined,
len: u8 = 0,
source: core.AgentTitleSource = .telar,
state: core.AgentTitleState = .placeholder,
phase: Agent.TitlePhase = .waiting_query,
capture: CaptureType = .{},

pub fn slice(title: *const Title) []const u8 {
    return title.bytes[0..title.len];
}

pub fn clearSensitive(title: *Title) void {
    title.capture.clear();
}
