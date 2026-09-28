//! OpenCode: resumable by its `ses_` session id with `opencode --session`,
//! the command OpenCode itself prints when it exits. Its plugin reports
//! prompts, permissions, questions and turn ends, so neither the screen nor
//! process presence decides its state.

const Capabilities = @import("Capabilities.zig");
const std = @import("std");

pub const capabilities: Capabilities = .{
    .completion_requires_agent_signal = true,
    .resume_prefix = "opencode --session ",
    .session_format = .opencode,
};

test {
    std.testing.refAllDecls(@This());
}
