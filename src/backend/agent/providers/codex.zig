//! Codex is resumable by session id. `history.codex_screen` reads its live
//! composer and status rows, excluding transcript quotes. A Stop hook reports
//! settlement pending confirmation by a newer, complete idle screen. Active
//! tool reports and intermediate model responses never announce completion.
//! Since 0.159, without `--no-daemon` the interactive CLI hands its session
//! to the shared `codex app-server` daemon, whose hooks run outside the
//! pane. A restore resumes with the flag only when the session ran with it:
//! older versions and non-interactive subcommands refuse it.

const Capabilities = @import("Capabilities.zig");
const core = @import("telar-core");
const std = @import("std");

pub const capabilities: Capabilities = .{
    .completion_requires_agent_signal = true,
    .resume_prefix = "codex resume ",
    .pane_session_argument = "--no-daemon",
    .hook_settings = core.HookSettings.codex,
    .batch_arguments = &.{
        "exec",
        "e",
        "review",
        "login",
        "logout",
        "mcp",
        "mcp-server",
        "plugin",
        "app-server",
        "remote-control",
        "app",
        "completion",
        "update",
        "doctor",
        "sandbox",
        "debug",
        "apply",
        "a",
        "queue",
        "archive",
        "delete",
        "migrate-rollouts",
        "unarchive",
        "cloud",
        "exec-server",
        "features",
        "agents",
        "help",
        "--help",
        "-h",
        "--version",
        "-V",
    },
    .ready_prompt_settles_report = true,
    .screen_shows_idle = true,
};

test {
    std.testing.refAllDecls(@This());
}
