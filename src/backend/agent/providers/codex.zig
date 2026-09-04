//! Codex: resumable by session id. Its manifest carries the ready prompt
//! phrase, so no glyph scan applies to it. That phrase is the composer
//! placeholder, which stays on screen while a turn runs, so it proves
//! readiness only once the status line above it is gone; matching happens on
//! the visible screen for that reason. Codex runs `Stop` hooks before other
//! hooks may continue the turn, so a `working` report from that hook is
//! settled only by the newer input prompt.

const std = @import("std");
const root = @import("root.zig");

pub const capabilities: root.Capabilities = .{
    .resume_prefix = "codex resume ",
    .ready_prompt_settles_report = true,
};

test {
    std.testing.refAllDecls(@This());
}
