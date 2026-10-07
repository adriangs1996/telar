//! Claude Code: resumable by session id. Its idle prompt is a bare `❯`, read
//! off the live screen by `history.prompt_scan`.

const Capabilities = @import("Capabilities.zig");

pub const capabilities: Capabilities = .{
    .resume_prefix = "claude --resume ",
    .screen_shows_idle = true,
};
