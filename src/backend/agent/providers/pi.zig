//! Pi: resumable by session id. Pi shows no permission prompts and no fixed
//! status phrases; its state comes from process detection, the proxy and its
//! own lifecycle reports through the Telar extension.

const std = @import("std");
const root = @import("root.zig");

pub const capabilities: root.Capabilities = .{
    .completion_requires_agent_signal = true,
    .resume_prefix = "pi --session ",
};

test {
    std.testing.refAllDecls(@This());
}
