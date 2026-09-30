//! Codex is resumable by session id. `history.codex_screen` reads its live
//! composer and status rows, excluding transcript quotes. A Stop hook reports
//! settlement pending confirmation by a newer, complete idle screen. Active
//! tool reports and intermediate model responses never announce completion.
//! Without `--no-daemon` the CLI hands its session to the shared
//! `codex app-server` daemon, whose hooks run outside the pane; a restore
//! therefore resumes with the flag.

const Capabilities = @import("Capabilities.zig");
const std = @import("std");

pub const capabilities: Capabilities = .{
    .completion_requires_agent_signal = true,
    .resume_prefix = "codex resume --no-daemon ",
    .pane_session_argument = "--no-daemon",
    .ready_prompt_settles_report = true,
    .screen_shows_idle = true,
};

test {
    std.testing.refAllDecls(@This());
}
