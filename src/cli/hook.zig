//! `telar hook <agent>`: the command an agent's lifecycle hooks run. It
//! reads the hook's JSON from stdin, maps the event to one official report
//! and sends it to the runtime that owns the pane. It never fails loudly:
//! outside a telar pane, or on any error, it exits 0 so the agent is
//! unaffected.

const std = @import("std");
const core = @import("telar-core");
const control = @import("control.zig");
const parser = @import("parser.zig");

const Io = std.Io;
const File = Io.File;
const schema = core.schema;

pub const max_input_bytes = 64 * 1024;

pub const Report = struct {
    state: schema.AgentReportState,
    session: []const u8 = "",
};

/// The subset of Claude Code hook input telar reads.
pub const ClaudeHookInput = struct {
    hook_event_name: []const u8 = "",
    session_id: []const u8 = "",
    agent_id: ?[]const u8 = null,
    notification_type: []const u8 = "",
    tool_name: []const u8 = "",
    tool_use_id: []const u8 = "",
    tool_input: std.json.Value = .null,
    cwd: []const u8 = "",
};

/// The subset of Codex hook input telar reads.
pub const CodexHookInput = struct {
    hook_event_name: []const u8 = "",
    session_id: []const u8 = "",
    agent_id: ?[]const u8 = null,
    source: []const u8 = "",
    tool_name: []const u8 = "",
    tool_use_id: []const u8 = "",
    tool_input: std.json.Value = .null,
    cwd: []const u8 = "",
};

/// The payload the Telar extension for Pi sends. Pi has no hook files: the
/// extension installed by `telar integration install pi` runs
/// `telar hook pi` on Pi's own extension events.
pub const PiHookInput = struct {
    event: []const u8 = "",
    session_id: []const u8 = "",
    /// Whether Pi had no run in progress when the event fired.
    idle: ?bool = null,
    tool_name: []const u8 = "",
    tool_call_id: []const u8 = "",
    tool_input: std.json.Value = .null,
    cwd: []const u8 = "",
    exit_code: ?i32 = null,
};

const CommandReport = struct {
    phase: schema.AgentCommandPhase,
    provider: []const u8,
    tool_call_id: []const u8,
    command: []const u8,
    cwd: []const u8,
    session: []const u8,
    exit_code: ?i32,
};

const ToolHookInput = struct {
    event: []const u8,
    agent_id: ?[]const u8 = null,
    tool_name: []const u8,
    tool_call_id: []const u8,
    tool_input: std.json.Value,
    cwd: []const u8,
    session: []const u8,
    exit_code: ?i32,
};

/// Extracts a shell command using the provider's manifest mapping.
///
/// ```zig
/// const command = mapToolCommand(.claude, input) orelse return;
/// ```
fn mapToolCommand(provider: schema.AgentProvider, input: ToolHookInput) ?CommandReport {
    if (input.agent_id) |agent_id| {
        if (agent_id.len != 0) {
            return null;
        }
    }

    const phase: schema.AgentCommandPhase = if (std.mem.eql(u8, input.event, "PreToolUse") or
        std.mem.eql(u8, input.event, "tool_execution_start"))
        .started
    else if (std.mem.eql(u8, input.event, "PostToolUse") or
        std.mem.eql(u8, input.event, "tool_execution_end"))
        .finished
    else
        return null;
    const field = core.agent_manifest.builtin_table.commandField(provider, input.tool_name) orelse return null;
    if (input.tool_input != .object) {
        return null;
    }
    const value = input.tool_input.object.get(field) orelse return null;
    if (value != .string or value.string.len == 0) {
        return null;
    }

    const session = if (schema.validateSessionReference(input.session)) |_| input.session else |_| "";
    return .{
        .phase = phase,
        .provider = core.agent_manifest.builtin_table.providerName(provider),
        .tool_call_id = input.tool_call_id,
        .command = value.string,
        .cwd = input.cwd,
        .session = session,
        .exit_code = if (phase == .finished) input.exit_code else null,
    };
}

/// Maps one Pi extension event to a report. A closed UI prompt reports
/// `working` while a run continues and `ready` when Pi was idle.
///
/// ```zig
/// const report = mapPiHook(input) orelse return;
/// ```
pub fn mapPiHook(input: PiHookInput) ?Report {
    const event = input.event;
    const session = if (schema.validateSessionReference(input.session_id)) |_| input.session_id else |_| "";

    if (std.mem.eql(u8, event, "session_start")) {
        return .{ .state = .ready, .session = session };
    }
    if (std.mem.eql(u8, event, "agent_start")) {
        return .{ .state = .working, .session = session };
    }
    if (std.mem.eql(u8, event, "agent_settled")) {
        return .{ .state = .ready, .session = session };
    }
    if (std.mem.eql(u8, event, "ui_prompt_start")) {
        return .{ .state = .blocked, .session = session };
    }
    if (std.mem.eql(u8, event, "ui_prompt_end")) {
        return .{ .state = if (input.idle == true) .ready else .working, .session = session };
    }
    if (std.mem.eql(u8, event, "session_shutdown")) {
        return .{ .state = .exited };
    }

    return null;
}

/// Maps one Claude Code hook event to a report. Subagent events and
/// notifications that do not change what the user must do are ignored.
///
/// ```zig
/// const report = mapClaudeHook(input) orelse return;
/// ```
pub fn mapClaudeHook(input: ClaudeHookInput) ?Report {
    if (input.agent_id != null and input.agent_id.?.len != 0) {
        return null;
    }

    const event = input.hook_event_name;
    const session = if (schema.validateSessionReference(input.session_id)) |_| input.session_id else |_| "";

    if (std.mem.eql(u8, event, "SessionStart")) {
        return .{ .state = .ready, .session = session };
    }
    if (std.mem.eql(u8, event, "UserPromptSubmit")) {
        return .{ .state = .working, .session = session };
    }
    if (std.mem.eql(u8, event, "PreToolUse") or std.mem.eql(u8, event, "PostToolUse")) {
        return .{ .state = .working, .session = session };
    }
    if (std.mem.eql(u8, event, "Stop")) {
        return .{ .state = .ready, .session = session };
    }
    if (std.mem.eql(u8, event, "SessionEnd")) {
        return .{ .state = .exited };
    }
    if (std.mem.eql(u8, event, "Notification")) {
        for ([_][]const u8{ "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input" }) |blocked| {
            if (std.mem.eql(u8, input.notification_type, blocked)) {
                return .{ .state = .blocked, .session = session };
            }
        }
        if (std.mem.eql(u8, input.notification_type, "idle_prompt")) {
            return .{ .state = .ready, .session = session };
        }

        return null;
    }

    return null;
}

/// Maps one Codex hook event to a report. Subagent events are ignored. A
/// compacted session and `Stop` remain working because neither event proves
/// that Codex returned to its input prompt.
///
/// ```zig
/// const report = mapCodexHook(input) orelse return;
/// ```
pub fn mapCodexHook(input: CodexHookInput) ?Report {
    if (input.agent_id != null and input.agent_id.?.len != 0) {
        return null;
    }

    const event = input.hook_event_name;
    const session = if (schema.validateSessionReference(input.session_id)) |_| input.session_id else |_| "";

    if (std.mem.eql(u8, event, "SessionStart")) {
        const state: schema.AgentReportState = if (std.mem.eql(u8, input.source, "compact")) .working else .ready;
        return .{ .state = state, .session = session };
    }
    if (std.mem.eql(u8, event, "UserPromptSubmit") or std.mem.eql(u8, event, "PreToolUse") or std.mem.eql(u8, event, "PostToolUse")) {
        return .{ .state = .working, .session = session };
    }
    if (std.mem.eql(u8, event, "PermissionRequest")) {
        return .{ .state = .blocked, .session = session };
    }
    if (std.mem.eql(u8, event, "Stop")) {
        return .{ .state = .working, .session = session };
    }

    if (std.mem.eql(u8, event, "Interrupt")) {
        return .{ .state = .ready, .session = session };
    }
    if (std.mem.eql(u8, event, "SessionEnd")) {
        return .{ .state = .exited };
    }

    return null;
}

/// Runs the hook for `options.agent`. Always exits 0.
///
/// ```zig
/// try hook.run(process_init, options);
/// ```
pub fn run(init: std.process.Init, options: parser.HookOptions) !void {
    const environ = init.minimal.environ;
    const pane_id = control.currentPaneId(environ) catch return;
    const generation_text = std.process.Environ.getPosix(environ, "TELAR_PANE_GENERATION") orelse return;
    const pane_generation = std.fmt.parseUnsigned(u64, generation_text, 10) catch return;

    const input = try init.gpa.alloc(u8, max_input_bytes);
    defer init.gpa.free(input);
    var stdin_reader = File.stdin().readerStreaming(init.io, &.{});
    const len = stdin_reader.interface.readSliceShort(input) catch return;
    const pane: control.PaneRef = .{ .pane_id = pane_id, .pane_generation = pane_generation };
    switch (options.agent) {
        .claude => {
            const parsed = std.json.parseFromSlice(ClaudeHookInput, init.gpa, input[0..len], .{ .ignore_unknown_fields = true }) catch return;
            defer parsed.deinit();
            const command = mapToolCommand(.claude, .{
                .event = parsed.value.hook_event_name,
                .agent_id = parsed.value.agent_id,
                .tool_name = parsed.value.tool_name,
                .tool_call_id = parsed.value.tool_use_id,
                .tool_input = parsed.value.tool_input,
                .cwd = parsed.value.cwd,
                .session = parsed.value.session_id,
                .exit_code = if (std.mem.eql(u8, parsed.value.hook_event_name, "PostToolUse")) 0 else null,
            });
            sendReports(init, options.socket, pane, mapClaudeHook(parsed.value), command);
        },
        .codex => {
            const parsed = std.json.parseFromSlice(CodexHookInput, init.gpa, input[0..len], .{ .ignore_unknown_fields = true }) catch return;
            defer parsed.deinit();
            const command = mapToolCommand(.codex, .{
                .event = parsed.value.hook_event_name,
                .agent_id = parsed.value.agent_id,
                .tool_name = parsed.value.tool_name,
                .tool_call_id = parsed.value.tool_use_id,
                .tool_input = parsed.value.tool_input,
                .cwd = parsed.value.cwd,
                .session = parsed.value.session_id,
                .exit_code = null,
            });
            sendReports(init, options.socket, pane, mapCodexHook(parsed.value), command);
        },
        .pi => {
            const parsed = std.json.parseFromSlice(PiHookInput, init.gpa, input[0..len], .{ .ignore_unknown_fields = true }) catch return;
            defer parsed.deinit();
            const command = mapToolCommand(.pi, .{
                .event = parsed.value.event,
                .tool_name = parsed.value.tool_name,
                .tool_call_id = parsed.value.tool_call_id,
                .tool_input = parsed.value.tool_input,
                .cwd = parsed.value.cwd,
                .session = parsed.value.session_id,
                .exit_code = parsed.value.exit_code,
            });
            sendReports(init, options.socket, pane, mapPiHook(parsed.value), command);
        },
    }
}

fn sendReports(init: std.process.Init, socket: ?[*:0]const u8, pane: control.PaneRef, report: ?Report, command: ?CommandReport) void {
    if (report == null and command == null) {
        return;
    }

    var session = control.Session.open(init, socket) catch return;
    defer session.close();
    if (report) |lifecycle| {
        session.reportAgent(pane, lifecycle.state, lifecycle.session) catch return;
    }
    if (command) |tool| {
        session.reportAgentCommand(pane, .{
            .phase = tool.phase,
            .provider = tool.provider,
            .tool_call_id = tool.tool_call_id,
            .command = tool.command,
            .cwd = tool.cwd,
            .session = tool.session,
            .exit_code = tool.exit_code,
        }) catch return;
    }
}

test "Pi extension events map to reports and prompts close into the right state" {
    const session = "01a061a3-a2e7-7574-9e07-997b8d59340d";
    const start = mapPiHook(.{ .event = "session_start", .session_id = session }).?;
    try std.testing.expectEqual(schema.AgentReportState.ready, start.state);
    try std.testing.expectEqualStrings(session, start.session);
    try std.testing.expectEqual(schema.AgentReportState.working, mapPiHook(.{ .event = "agent_start" }).?.state);
    try std.testing.expectEqual(schema.AgentReportState.ready, mapPiHook(.{ .event = "agent_settled" }).?.state);
    try std.testing.expectEqual(schema.AgentReportState.blocked, mapPiHook(.{ .event = "ui_prompt_start" }).?.state);
    try std.testing.expectEqual(schema.AgentReportState.working, mapPiHook(.{ .event = "ui_prompt_end", .idle = false }).?.state);
    try std.testing.expectEqual(schema.AgentReportState.working, mapPiHook(.{ .event = "ui_prompt_end" }).?.state);
    try std.testing.expectEqual(schema.AgentReportState.ready, mapPiHook(.{ .event = "ui_prompt_end", .idle = true }).?.state);
    try std.testing.expectEqual(schema.AgentReportState.exited, mapPiHook(.{ .event = "session_shutdown" }).?.state);
    try std.testing.expect(mapPiHook(.{ .event = "tool_execution_start" }) == null);
    try std.testing.expectEqualStrings("", mapPiHook(.{ .event = "agent_start", .session_id = "../etc" }).?.session);
}

test "Pi hook JSON accepts the extension payload" {
    const parsed = try std.json.parseFromSlice(PiHookInput, std.testing.allocator, "{\"event\":\"session_start\",\"session_id\":\"01a061a3-a2e7-7574-9e07-997b8d59340d\",\"idle\":true}", .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const report = mapPiHook(parsed.value).?;
    try std.testing.expectEqual(schema.AgentReportState.ready, report.state);
    try std.testing.expectEqualStrings("01a061a3-a2e7-7574-9e07-997b8d59340d", report.session);
    try std.testing.expectError(error.SyntaxError, std.json.parseFromSlice(PiHookInput, std.testing.allocator, "not json", .{ .ignore_unknown_fields = true }));
}

test "Claude hook events map to reports and subagents are ignored" {
    const session = "0192aaaa-bbbb-cccc-dddd-eeeeffff0000";
    const start = mapClaudeHook(.{ .hook_event_name = "SessionStart", .session_id = session }).?;
    try std.testing.expectEqual(schema.AgentReportState.ready, start.state);
    try std.testing.expectEqualStrings(session, start.session);
    try std.testing.expectEqual(schema.AgentReportState.working, mapClaudeHook(.{ .hook_event_name = "UserPromptSubmit" }).?.state);
    try std.testing.expectEqual(schema.AgentReportState.ready, mapClaudeHook(.{ .hook_event_name = "Stop" }).?.state);
    try std.testing.expectEqual(schema.AgentReportState.exited, mapClaudeHook(.{ .hook_event_name = "SessionEnd" }).?.state);
    try std.testing.expectEqual(schema.AgentReportState.blocked, mapClaudeHook(.{ .hook_event_name = "Notification", .notification_type = "permission_prompt" }).?.state);
    try std.testing.expectEqual(schema.AgentReportState.ready, mapClaudeHook(.{ .hook_event_name = "Notification", .notification_type = "idle_prompt" }).?.state);
    try std.testing.expect(mapClaudeHook(.{ .hook_event_name = "Notification", .notification_type = "auth_success" }) == null);
    try std.testing.expectEqual(schema.AgentReportState.working, mapClaudeHook(.{ .hook_event_name = "PreToolUse" }).?.state);
    try std.testing.expect(mapClaudeHook(.{ .hook_event_name = "Stop", .agent_id = "sub-1" }) == null);
    try std.testing.expectEqualStrings("", mapClaudeHook(.{ .hook_event_name = "Stop", .session_id = "bad session" }).?.session);
}

test "Codex hook events map to reports and subagents are ignored" {
    const session = "0192aaaa-bbbb-cccc-dddd-eeeeffff0000";
    const start = mapCodexHook(.{ .hook_event_name = "SessionStart", .session_id = session }).?;
    try std.testing.expectEqual(schema.AgentReportState.ready, start.state);
    try std.testing.expectEqualStrings(session, start.session);
    try std.testing.expectEqual(schema.AgentReportState.working, mapCodexHook(.{ .hook_event_name = "SessionStart", .source = "compact" }).?.state);
    try std.testing.expectEqual(schema.AgentReportState.working, mapCodexHook(.{ .hook_event_name = "UserPromptSubmit" }).?.state);
    try std.testing.expectEqual(schema.AgentReportState.blocked, mapCodexHook(.{ .hook_event_name = "PermissionRequest" }).?.state);
    try std.testing.expectEqual(schema.AgentReportState.working, mapCodexHook(.{ .hook_event_name = "PostToolUse" }).?.state);
    try std.testing.expectEqual(schema.AgentReportState.working, mapCodexHook(.{ .hook_event_name = "Stop" }).?.state);
    try std.testing.expectEqual(schema.AgentReportState.ready, mapCodexHook(.{ .hook_event_name = "Interrupt" }).?.state);
    try std.testing.expectEqual(schema.AgentReportState.exited, mapCodexHook(.{ .hook_event_name = "SessionEnd" }).?.state);
    try std.testing.expectEqual(schema.AgentReportState.working, mapCodexHook(.{ .hook_event_name = "PreToolUse" }).?.state);
    try std.testing.expect(mapCodexHook(.{ .hook_event_name = "PostToolUse", .agent_id = "sub-1" }) == null);
    try std.testing.expectEqualStrings("", mapCodexHook(.{ .hook_event_name = "Stop", .session_id = "bad session" }).?.session);
}

test "installed harness payloads map shell tools through manifests" {
    const session = "0192aaaa-bbbb-cccc-dddd-eeeeffff0000";
    const codex_payload =
        \\{"session_id":"0192aaaa-bbbb-cccc-dddd-eeeeffff0000","turn_id":"turn-1","cwd":"/work","hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"call-7","tool_input":{"command":"zig build test"}}
    ;
    const codex = try std.json.parseFromSlice(CodexHookInput, std.testing.allocator, codex_payload, .{ .ignore_unknown_fields = true });
    defer codex.deinit();
    const codex_command = mapToolCommand(.codex, .{
        .event = codex.value.hook_event_name,
        .agent_id = codex.value.agent_id,
        .tool_name = codex.value.tool_name,
        .tool_call_id = codex.value.tool_use_id,
        .tool_input = codex.value.tool_input,
        .cwd = codex.value.cwd,
        .session = codex.value.session_id,
        .exit_code = null,
    }).?;
    try std.testing.expectEqual(schema.AgentCommandPhase.started, codex_command.phase);
    try std.testing.expectEqualStrings("codex", codex_command.provider);
    try std.testing.expectEqualStrings("call-7", codex_command.tool_call_id);
    try std.testing.expectEqualStrings("zig build test", codex_command.command);
    try std.testing.expectEqualStrings(session, codex_command.session);

    const claude_payload =
        \\{"session_id":"0192aaaa-bbbb-cccc-dddd-eeeeffff0000","cwd":"/work","hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"toolu_1","tool_input":{"command":"npm test"}}
    ;
    const claude = try std.json.parseFromSlice(ClaudeHookInput, std.testing.allocator, claude_payload, .{ .ignore_unknown_fields = true });
    defer claude.deinit();
    const claude_command = mapToolCommand(.claude, .{
        .event = claude.value.hook_event_name,
        .agent_id = claude.value.agent_id,
        .tool_name = claude.value.tool_name,
        .tool_call_id = claude.value.tool_use_id,
        .tool_input = claude.value.tool_input,
        .cwd = claude.value.cwd,
        .session = claude.value.session_id,
        .exit_code = 0,
    }).?;
    try std.testing.expectEqual(schema.AgentCommandPhase.finished, claude_command.phase);
    try std.testing.expectEqualStrings("npm test", claude_command.command);

    const pi_payload =
        \\{"event":"tool_execution_end","session_id":"01a061a3-a2e7-7574-9e07-997b8d59340d","tool_name":"bash","tool_call_id":"pi-3","tool_input":{"command":"git status"},"cwd":"/work","exit_code":1}
    ;
    const pi = try std.json.parseFromSlice(PiHookInput, std.testing.allocator, pi_payload, .{ .ignore_unknown_fields = true });
    defer pi.deinit();
    const pi_command = mapToolCommand(.pi, .{
        .event = pi.value.event,
        .tool_name = pi.value.tool_name,
        .tool_call_id = pi.value.tool_call_id,
        .tool_input = pi.value.tool_input,
        .cwd = pi.value.cwd,
        .session = pi.value.session_id,
        .exit_code = pi.value.exit_code,
    }).?;
    try std.testing.expectEqual(@as(?i32, 1), pi_command.exit_code);

    var subagent = codex.value;
    subagent.agent_id = "sub-1";
    try std.testing.expect(mapToolCommand(.codex, .{
        .event = subagent.hook_event_name,
        .agent_id = subagent.agent_id,
        .tool_name = subagent.tool_name,
        .tool_call_id = subagent.tool_use_id,
        .tool_input = subagent.tool_input,
        .cwd = subagent.cwd,
        .session = subagent.session_id,
        .exit_code = null,
    }) == null);
}
