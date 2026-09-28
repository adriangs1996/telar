const core = @import("telar-core");
const std = @import("std");
/// The payload the Telar plugin for OpenCode sends. OpenCode has no hook
/// files: the plugin installed by `telar integration install opencode` runs
/// `telar hook opencode` on OpenCode's own plugin events and hooks, and keeps
/// the pane state they imply.
const OpenCodeHookInput = @This();

/// OpenCode's event or hook name, or `load`, `state_snapshot` and `dispose`
/// from the plugin itself.
event: []const u8 = "",
/// The root session the pane shows, `ses_` and 26 characters.
session_id: []const u8 = "",
/// Whether the root session had a turn running when the event fired.
busy: bool = false,
/// The open prompt the user has to answer: `permission` or `question`.
blocked: core.AgentBlockedReason = .none,
/// The session title on `session.updated`, OpenCode's default one included.
title: ?[]const u8 = null,
/// The tool on tool events, the permission on `permission.asked`.
tool_name: []const u8 = "",
tool_call_id: []const u8 = "",
/// The tool's arguments, the permission's metadata or `{ questions }`.
tool_input: std.json.Value = .null,
cwd: []const u8 = "",
/// The shell tool's exit status on `tool.execute.after`; absent when the
/// command was aborted or timed out.
exit_code: ?i32 = null,
