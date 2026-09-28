//! Pi: resumable by session id. Pi shows no permission prompts and no fixed
//! status phrases; its state comes from process detection and its own
//! lifecycle reports through the Telar extension.

const Capabilities = @import("Capabilities.zig");
const std = @import("std");

pub const capabilities: Capabilities = .{
    .completion_requires_agent_signal = true,
    .resume_prefix = "pi --session ",
};

test {
    std.testing.refAllDecls(@This());
}
