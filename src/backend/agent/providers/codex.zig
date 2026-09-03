//! Codex: resumable by session id. Its manifest carries the ready prompt
//! phrase, so no screen scan applies to it. Codex runs `Stop` hooks before
//! other hooks may continue the turn, so a `working` report from that hook is
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
