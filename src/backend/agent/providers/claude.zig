//! Claude Code: resumable by session id. Its idle prompt is a bare `❯`, read
//! off the live screen by `history.prompt_scan`.

const CapabilitiesType = @import("Capabilities.zig");
const std = @import("std");

pub const capabilities: CapabilitiesType = .{
    .resume_prefix = "claude --resume ",
};

test {
    std.testing.refAllDecls(@This());
}
