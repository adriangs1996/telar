const std = @import("std");
/// The subset of Codex hook input telar reads.
const CodexHookInput = @This();

hook_event_name: []const u8 = "",
session_id: []const u8 = "",
agent_id: ?[]const u8 = null,
source: []const u8 = "",
tool_name: []const u8 = "",
tool_use_id: []const u8 = "",
tool_input: std.json.Value = .null,
cwd: []const u8 = "",
/// The rollout of the thread the event belongs to: the session's own for
/// `Stop` and `Interrupt`, the parent's for `SubagentStop`.
transcript_path: []const u8 = "",
/// Not part of Codex's payload: the state database `run` resolves from
/// `CODEX_HOME`, where `/rename` lands as `threads.name`.
state_database: []const u8 = "",
/// Not part of Codex's payload: the subagents `run` finds still running
/// in `transcript_path`, leaving out the one a `SubagentStop` reports.
running_subagents: usize = 0,
