const core = @import("telar-core");
const Agent = @import("Agent.zig");
const Capture = @import("Capture.zig");
const Title = @This();

bytes: [core.max_agent_session_title_bytes]u8 = undefined,
len: u8 = 0,
source: core.AgentTitleSource = .telar,
state: core.AgentTitleState = .placeholder,
phase: Agent.TitlePhase = .waiting_query,
capture: Capture = .{},

pub fn slice(self: *const Title) []const u8 {
    return self.bytes[0..self.len];
}

pub fn clearSensitive(self: *Title) void {
    self.capture.clear();
}
