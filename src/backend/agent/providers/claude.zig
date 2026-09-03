//! Claude Code: resumable by session id. Its idle prompt is a bare `❯`, read
//! off the live screen by `history.prompt_scan`.

const std = @import("std");
const root = @import("root.zig");

pub const capabilities: root.Capabilities = .{
    .resume_prefix = "claude --resume ",
};

test {
    std.testing.refAllDecls(@This());
}
