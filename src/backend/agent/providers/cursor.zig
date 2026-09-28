//! Cursor Agent: resumable by chat id. Its hooks report prompts, tool calls
//! and turn ends, but none fires for a command approval or a plan review,
//! so those reach the runtime only as blocked screens.

const Capabilities = @import("Capabilities.zig");
const std = @import("std");

pub const capabilities: Capabilities = .{
    .completion_requires_agent_signal = true,
    .resume_prefix = "cursor-agent --resume ",
    .screen_reports_blocked = true,
    .screen_shows_idle = true,
};

test {
    std.testing.refAllDecls(@This());
}
