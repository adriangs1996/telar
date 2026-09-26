//! `telar hook <agent>`: the command an agent's lifecycle hooks run. It
//! reads the hook's JSON from stdin, maps the event to one official report
//! and sends it to the runtime that owns the pane. It never fails loudly:
//! outside a telar pane, or on any error, it exits 0 so the agent is
//! unaffected.

const core = @import("telar-core");
const ToolHookInput = @import("ToolHookInput.zig");
const hook_review = @import("hook_review.zig");
const CommandReport = @import("CommandReport.zig");
const std = @import("std");
const PiHookInput = @import("PiHookInput.zig");
const Report = @import("Report.zig");
const ClaudeHookInput = @import("ClaudeHookInput.zig");
const CodexHookInput = @import("CodexHookInput.zig");
const HookOptions = @import("arguments/HookOptions.zig");
const control = @import("control.zig");
const Target = @import("Target.zig");
const Reports = @import("Reports.zig");
const Session = @import("Session.zig");
const hook_event = @import("hook_event.zig");
const CodexSubagents = @import("CodexSubagents.zig");

pub const max_input_bytes = 64 * 1024;

/// Extracts a shell command using the provider's manifest mapping.
///
/// ```zig
/// const command = mapToolCommand(.claude, input) orelse return;
/// ```
fn mapToolCommand(provider: core.AgentProvider, input: ToolHookInput) ?CommandReport {
    if (input.agent_id) |agent_id| {
        if (agent_id.len != 0) {
            return null;
        }
    }

    const phase: core.AgentCommandPhase = if (std.mem.eql(u8, input.event, "PreToolUse") or
        std.mem.eql(u8, input.event, "tool_execution_start"))
        .started
    else if (std.mem.eql(u8, input.event, "PostToolUse") or
        std.mem.eql(u8, input.event, "tool_execution_end"))
        .finished
    else
        return null;
    const field = core.builtin_table.commandField(provider, input.tool_name) orelse return null;
    if (input.tool_input != .object) {
        return null;
    }
    const value = input.tool_input.object.get(field) orelse return null;
    if (value != .string or value.string.len == 0) {
        return null;
    }

    const session = if (core.validateSessionReference(input.session)) |_| input.session else |_| "";
    return .{
        .phase = phase,
        .provider = core.builtin_table.providerName(provider),
        .tool_call_id = input.tool_call_id,
        .command = value.string,
        .cwd = input.cwd,
        .session = session,
        .exit_code = if (phase == .finished) input.exit_code else null,
    };
}

/// Maps one Pi extension event to a report. A closed UI prompt reports
/// `working` while a run continues and `ready` when Pi was idle. Pi shows
/// no permission prompts, so every blocked state is an extension dialog:
/// a question.
///
/// ```zig
/// const report = mapPiHook(input) orelse return;
/// ```
pub fn mapPiHook(input: PiHookInput) ?Report {
    const event = input.event;
    const session = if (core.validateSessionReference(input.session_id)) |_| input.session_id else |_| "";

    if (std.mem.eql(u8, event, "session_start") or
        std.mem.eql(u8, event, "agent_settled") or
        std.mem.eql(u8, event, "ui_prompt_end") or
        std.mem.eql(u8, event, "state_snapshot"))
    {
        const idle = input.idle orelse (std.mem.eql(u8, event, "session_start") or std.mem.eql(u8, event, "agent_settled"));
        if (input.blocked) {
            return .{ .state = .blocked, .blocked_reason = .question, .session = session };
        }

        return .{ .state = if (idle) .ready else .working, .session = session };
    }

    if (std.mem.eql(u8, event, "agent_start")) {
        return .{ .state = .working, .session = session };
    }

    if (std.mem.eql(u8, event, "ui_prompt_start")) {
        return .{ .state = .blocked, .blocked_reason = .question, .session = session };
    }

    if (std.mem.eql(u8, event, "session_shutdown")) {
        return .{ .state = .exited };
    }

    return null;
}

/// Maps the session name Pi carries to a title report. `session_start`
/// reports a name only when the session has one, so a resumed named session
/// is titled at once; `session_info_changed` reports every change, and a
/// cleared name as an empty title. Long names are cut on a UTF-8 boundary.
///
/// ```zig
/// const title = mapPiTitle(&buffer, input) orelse return;
/// ```
pub fn mapPiTitle(buffer: *[core.max_agent_session_title_bytes]u8, input: PiHookInput) ?[]const u8 {
    const name = if (std.mem.eql(u8, input.event, "session_info_changed"))
        input.name orelse ""
    else if (std.mem.eql(u8, input.event, "session_start"))
        input.name orelse return null
    else
        return null;

    return core.truncateSessionTitle(buffer, name);
}

/// Maps one Claude Code hook event to a report. A subagent's tool calls
/// only renew the work already reported, and notifications that do not
/// change what the user must do are ignored. `AskUserQuestion` and
/// `ExitPlanMode` block before their tool runs, so their `PreToolUse`
/// reports the question or the plan review instead of work. A `Stop` that
/// leaves subagents running reports `waiting` until the turn that collects
/// the last of them, and the idle prompt reports `idle`, which cannot
/// settle that wait. The event line borrows `buffer`.
///
/// ```zig
/// const report = mapClaudeHook(input, &buffer) orelse return;
/// ```
pub fn mapClaudeHook(input: ClaudeHookInput, buffer: *hook_event.Buffer) ?Report {
    const session_file = if (input.transcript_path.len <= core.max_agent_session_file_bytes) input.transcript_path else "";
    const event = input.hook_event_name;
    if (input.agent_id != null and input.agent_id.?.len != 0) {
        if (std.mem.eql(u8, event, "PreToolUse") or std.mem.eql(u8, event, "PostToolUse")) {
            return .{ .state = .continuing };
        }

        return null;
    }

    const session = if (core.validateSessionReference(input.session_id)) |_| input.session_id else |_| "";

    if (std.mem.eql(u8, event, "SessionStart")) {
        return .{ .state = .ready, .session = session, .session_file = session_file };
    }
    if (std.mem.eql(u8, event, "UserPromptSubmit")) {
        return .{ .state = .working, .session = session, .session_file = session_file };
    }
    if (std.mem.eql(u8, event, "PreToolUse") and std.mem.eql(u8, input.tool_name, "AskUserQuestion")) {
        const asked = hook_event.question(buffer, input.tool_input) orelse hook_event.toolCall(buffer, input.tool_name, input.tool_input) orelse "";
        return .{ .state = .blocked, .blocked_reason = .question, .event = asked, .session = session, .session_file = session_file };
    }
    if (std.mem.eql(u8, event, "PreToolUse") and std.mem.eql(u8, input.tool_name, "ExitPlanMode")) {
        const call = hook_event.toolCall(buffer, input.tool_name, input.tool_input) orelse "";
        return .{ .state = .blocked, .blocked_reason = .plan, .event = call, .session = session, .session_file = session_file };
    }
    if (std.mem.eql(u8, event, "PreToolUse") or std.mem.eql(u8, event, "PostToolUse")) {
        const call = hook_event.toolCall(buffer, input.tool_name, input.tool_input) orelse "";
        return .{ .state = .working, .event = call, .session = session, .session_file = session_file };
    }
    if (std.mem.eql(u8, event, "Stop")) {
        const running = input.runningSubagents();
        if (running != 0) {
            return .{ .state = .waiting, .event = hook_event.backgroundAgents(buffer, running), .session = session, .session_file = session_file };
        }

        return .{ .state = .ready, .event = hook_event.line(buffer, input.last_assistant_message), .session = session, .session_file = session_file };
    }
    if (std.mem.eql(u8, event, "SessionEnd")) {
        return .{ .state = .exited, .session_file = session_file };
    }
    if (std.mem.eql(u8, event, "Notification")) {
        if (std.mem.eql(u8, input.notification_type, "permission_prompt")) {
            return .{ .state = .blocked, .blocked_reason = .permission, .event = hook_event.line(buffer, input.message), .session = session, .session_file = session_file };
        }
        for ([_][]const u8{ "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input" }) |asking| {
            if (std.mem.eql(u8, input.notification_type, asking)) {
                return .{ .state = .blocked, .blocked_reason = .question, .event = hook_event.line(buffer, input.message), .session = session, .session_file = session_file };
            }
        }
        if (std.mem.eql(u8, input.notification_type, "idle_prompt")) {
            return .{ .state = .idle, .session = session, .session_file = session_file };
        }

        return null;
    }

    return null;
}

/// Maps the name Claude Code hands its `SessionStart` hook to a title
/// report, so a session started or resumed with a name is titled at once.
/// Later renames reach the runtime through the transcript watch.
///
/// ```zig
/// const title = mapClaudeTitle(&buffer, input) orelse return;
/// ```
pub fn mapClaudeTitle(buffer: *[core.max_agent_session_title_bytes]u8, input: ClaudeHookInput) ?[]const u8 {
    if (!std.mem.eql(u8, input.hook_event_name, "SessionStart") or input.session_title.len == 0 or input.agent_id != null) {
        return null;
    }

    return core.truncateSessionTitle(buffer, input.session_title);
}

/// Codex's state directory: `CODEX_HOME`, else `~/.codex`.
fn codexHome(environ: std.process.Environ, buffer: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    if (std.process.Environ.getPosix(environ, "CODEX_HOME")) |home| {
        if (home.len != 0) {
            return std.fmt.bufPrint(buffer, "{s}", .{home}) catch null;
        }
    }

    const home = std.process.Environ.getPosix(environ, "HOME") orelse return null;
    return std.fmt.bufPrint(buffer, "{s}/.codex", .{home}) catch null;
}

/// Finds the current Codex state database, `state_<n>.sqlite` with the
/// highest schema number, where `/rename` stores the thread name.
///
/// ```zig
/// const database = codexStateDatabase(io, "/home/me/.codex", &buffer) orelse return;
/// ```
pub fn codexStateDatabase(io: std.Io, home: []const u8, buffer: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    var directory = std.Io.Dir.cwd().openDir(io, home, .{ .iterate = true }) catch return null;
    defer directory.close(io);
    var iterator = directory.iterate();
    var best: ?u32 = null;

    while (iterator.next(io) catch null) |entry| {
        if (entry.kind != .file) {
            continue;
        }

        const version = stateVersion(entry.name) orelse continue;
        if (best == null or version > best.?) {
            best = version;
        }
    }

    const version = best orelse return null;
    return std.fmt.bufPrint(buffer, "{s}/state_{d}.sqlite", .{ home, version }) catch null;
}

fn stateVersion(name: []const u8) ?u32 {
    const prefix = "state_";
    const suffix = ".sqlite";
    if (!std.mem.startsWith(u8, name, prefix) or !std.mem.endsWith(u8, name, suffix) or name.len <= prefix.len + suffix.len) {
        return null;
    }

    return std.fmt.parseUnsigned(u32, name[prefix.len .. name.len - suffix.len], 10) catch null;
}

/// Maps one Codex hook event to a report. A compacted session remains
/// working; `Stop` starts settlement, which still needs a newer idle
/// composer before it can announce completion. A `Stop` or `Interrupt` that
/// leaves subagents running reports `waiting` instead, a subagent's tool
/// calls renew that wait, and the `SubagentStop` of the last child the
/// session started reports `released`. Codex resumes no turn for a finished
/// child, so nothing else ends the wait. Tool events and permission
/// requests name their tool call in `buffer`.
///
/// ```zig
/// const report = mapCodexHook(input, &buffer) orelse return;
/// ```
pub fn mapCodexHook(input: CodexHookInput, buffer: *hook_event.Buffer) ?Report {
    const event = input.hook_event_name;
    if (input.agent_id != null and input.agent_id.?.len != 0) {
        if (std.mem.eql(u8, event, "PreToolUse") or std.mem.eql(u8, event, "PostToolUse")) {
            return .{ .state = .continuing };
        }

        // A nested child's stop names its parent's rollout, which does not
        // list the children the session is waiting for.
        if (std.mem.eql(u8, event, "SubagentStop") and input.running_subagents == 0 and isSessionRollout(input.transcript_path, input.session_id)) {
            return .{ .state = .released };
        }

        return null;
    }

    const session = if (core.validateSessionReference(input.session_id)) |_| input.session_id else |_| "";
    const file = if (input.state_database.len <= core.max_agent_session_file_bytes) input.state_database else "";
    if ((std.mem.eql(u8, event, "Stop") or std.mem.eql(u8, event, "Interrupt")) and input.running_subagents != 0) {
        return .{ .state = .waiting, .event = hook_event.backgroundAgents(buffer, input.running_subagents), .session = session, .session_file = file, .session_file_kind = .codex_state };
    }

    if (std.mem.eql(u8, event, "SessionStart")) {
        const state: core.AgentReportState = if (std.mem.eql(u8, input.source, "compact")) .working else .ready;
        return .{ .state = state, .session = session, .session_file = file, .session_file_kind = .codex_state };
    }
    if (std.mem.eql(u8, event, "UserPromptSubmit")) {
        return .{ .state = .working, .session = session, .session_file = file, .session_file_kind = .codex_state };
    }
    if (std.mem.eql(u8, event, "PreToolUse") or std.mem.eql(u8, event, "PostToolUse")) {
        const call = hook_event.toolCall(buffer, input.tool_name, input.tool_input) orelse "";
        return .{ .state = .working, .event = call, .session = session, .session_file = file, .session_file_kind = .codex_state };
    }
    if (std.mem.eql(u8, event, "PermissionRequest")) {
        const call = hook_event.toolCall(buffer, input.tool_name, input.tool_input) orelse "";
        return .{ .state = .blocked, .blocked_reason = .permission, .event = call, .session = session, .session_file = file, .session_file_kind = .codex_state };
    }
    if (std.mem.eql(u8, event, "Stop")) {
        return .{ .state = .settling, .session = session, .session_file = file, .session_file_kind = .codex_state };
    }

    if (std.mem.eql(u8, event, "Interrupt")) {
        return .{ .state = .ready, .session = session, .session_file = file, .session_file_kind = .codex_state };
    }
    if (std.mem.eql(u8, event, "SessionEnd")) {
        return .{ .state = .exited, .session_file = file, .session_file_kind = .codex_state };
    }

    return null;
}

/// Whether `path` is the rollout Codex writes for `session`, named
/// `rollout-<time>-<session>.jsonl`.
fn isSessionRollout(path: []const u8, session: []const u8) bool {
    const suffix = ".jsonl";
    if (session.len == 0 or path.len < session.len + suffix.len + 1 or !std.mem.endsWith(u8, path, suffix)) {
        return false;
    }

    const name_end = path.len - suffix.len;
    return std.mem.eql(u8, path[name_end - session.len .. name_end], session) and path[name_end - session.len - 1] == '-';
}

// Only the events that end a turn or a child read the rollout; a tool call
// never waits on it.
fn codexRunningSubagents(io: std.Io, input: *const CodexHookInput) usize {
    const event = input.hook_event_name;
    if (!std.mem.eql(u8, event, "Stop") and !std.mem.eql(u8, event, "Interrupt") and !std.mem.eql(u8, event, "SubagentStop")) {
        return 0;
    }

    const running = CodexSubagents.read(io, input.transcript_path);
    return running.countExcept(input.agent_id orelse "");
}

/// Runs the hook for `options.agent`. Always exits 0.
///
/// ```zig
/// try hook.run(process_init, options);
/// ```
pub fn run(init: std.process.Init, options: HookOptions) !void {
    const environ = init.minimal.environ;
    const pane_id = control.currentPaneId(environ) catch return;
    const generation_text = std.process.Environ.getPosix(environ, "TELAR_PANE_GENERATION") orelse return;
    const pane_generation = std.fmt.parseUnsigned(u64, generation_text, 10) catch return;

    const input = try init.gpa.alloc(u8, max_input_bytes);
    defer init.gpa.free(input);
    var stdin_reader = std.Io.File.stdin().readerStreaming(init.io, &.{});
    const len = stdin_reader.interface.readSliceShort(input) catch return;
    const target: Target = .{
        .socket = options.socket,
        .pane = .{ .pane_id = pane_id, .pane_generation = pane_generation },
    };
    switch (options.agent) {
        .claude => {
            const parsed = std.json.parseFromSlice(ClaudeHookInput, init.gpa, input[0..len], .{ .ignore_unknown_fields = true }) catch return;
            defer parsed.deinit();
            const tool: ToolHookInput = .{
                .event = parsed.value.hook_event_name,
                .agent_id = parsed.value.agent_id,
                .tool_name = parsed.value.tool_name,
                .tool_call_id = parsed.value.tool_use_id,
                .tool_input = parsed.value.tool_input,
                .cwd = parsed.value.cwd,
                .session = parsed.value.session_id,
                .exit_code = if (std.mem.eql(u8, parsed.value.hook_event_name, "PostToolUse")) 0 else null,
            };
            const command = mapToolCommand(.claude, tool);
            var title_buffer: [core.max_agent_session_title_bytes]u8 = undefined;
            var event_buffer: hook_event.Buffer = undefined;
            sendReports(init, target, .{
                .lifecycle = mapClaudeHook(parsed.value, &event_buffer),
                .command = command,
                .title = mapClaudeTitle(&title_buffer, parsed.value),
                .review = .{ .provider = .claude, .input = tool },
            });
        },
        .codex => {
            var parsed = std.json.parseFromSlice(CodexHookInput, init.gpa, input[0..len], .{ .ignore_unknown_fields = true }) catch return;
            defer parsed.deinit();
            var home_buffer: [std.fs.max_path_bytes]u8 = undefined;
            var database_buffer: [std.fs.max_path_bytes]u8 = undefined;
            if (codexHome(environ, &home_buffer)) |home| {
                parsed.value.state_database = codexStateDatabase(init.io, home, &database_buffer) orelse "";
            }

            parsed.value.running_subagents = codexRunningSubagents(init.io, &parsed.value);
            const tool: ToolHookInput = .{
                .event = parsed.value.hook_event_name,
                .agent_id = parsed.value.agent_id,
                .tool_name = parsed.value.tool_name,
                .tool_call_id = parsed.value.tool_use_id,
                .tool_input = parsed.value.tool_input,
                .cwd = parsed.value.cwd,
                .session = parsed.value.session_id,
                .exit_code = null,
            };
            const command = mapToolCommand(.codex, tool);
            var event_buffer: hook_event.Buffer = undefined;
            sendReports(init, target, .{ .lifecycle = mapCodexHook(parsed.value, &event_buffer), .command = command, .review = .{ .provider = .codex, .input = tool } });
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
            var title_buffer: [core.max_agent_session_title_bytes]u8 = undefined;
            sendReports(init, target, .{
                .lifecycle = mapPiHook(parsed.value),
                .command = command,
                .title = mapPiTitle(&title_buffer, parsed.value),
            });
        },
    }
}

fn sendReports(init: std.process.Init, target: Target, reports: Reports) void {
    if (reports.lifecycle == null and reports.command == null and reports.title == null and reports.review == null) {
        return;
    }

    // Attach only. The pane environment survives a stopped runtime, and a
    // hook that started one would resurrect it from every orphaned agent.
    var session = Session.attach(init, target.socket) catch return;
    defer session.close();
    const pane = target.pane;
    if (reports.lifecycle) |lifecycle| {
        session.reportAgent(pane, .{
            .state = lifecycle.state,
            .blocked_reason = lifecycle.blocked_reason,
            .event = lifecycle.event,
            .session = lifecycle.session,
            .session_file = lifecycle.session_file,
            .session_file_kind = lifecycle.session_file_kind,
        }) catch return;
    }
    if (reports.review) |review| {
        hook_review.capture(&session, pane, review);
    }
    if (reports.title) |title| {
        session.reportAgentTitle(pane, title) catch return;
    }
    if (reports.command) |tool| {
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
    if (reports.review) |review| {
        hook_review.feedback(&session, pane, review) catch {};
    }
}

test "Pi extension events map to reports and prompts close into the right state" {
    const session = "01a061a3-a2e7-7574-9e07-997b8d59340d";
    const start = mapPiHook(.{ .event = "session_start", .session_id = session }).?;
    try std.testing.expectEqual(core.AgentReportState.ready, start.state);
    try std.testing.expectEqualStrings(session, start.session);
    try std.testing.expectEqual(core.AgentReportState.working, mapPiHook(.{ .event = "agent_start" }).?.state);
    try std.testing.expectEqual(core.AgentReportState.ready, mapPiHook(.{ .event = "agent_settled" }).?.state);
    try std.testing.expectEqual(core.AgentReportState.blocked, mapPiHook(.{ .event = "ui_prompt_start" }).?.state);
    try std.testing.expectEqual(core.AgentReportState.working, mapPiHook(.{ .event = "ui_prompt_end", .idle = false }).?.state);
    try std.testing.expectEqual(core.AgentReportState.working, mapPiHook(.{ .event = "ui_prompt_end" }).?.state);
    try std.testing.expectEqual(core.AgentReportState.ready, mapPiHook(.{ .event = "ui_prompt_end", .idle = true }).?.state);
    try std.testing.expectEqual(core.AgentReportState.exited, mapPiHook(.{ .event = "session_shutdown" }).?.state);
    try std.testing.expect(mapPiHook(.{ .event = "tool_execution_start" }) == null);
    try std.testing.expectEqualStrings("", mapPiHook(.{ .event = "agent_start", .session_id = "../etc" }).?.session);
}

test "Pi session names map to title reports and a cleared name to an empty title" {
    var buffer: [core.max_agent_session_title_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("Fix proxy", mapPiTitle(&buffer, .{ .event = "session_info_changed", .name = "Fix proxy" }).?);
    try std.testing.expectEqualStrings("", mapPiTitle(&buffer, .{ .event = "session_info_changed" }).?);
    try std.testing.expectEqualStrings("Fix proxy", mapPiTitle(&buffer, .{ .event = "session_start", .name = "Fix proxy" }).?);
    try std.testing.expect(mapPiTitle(&buffer, .{ .event = "session_start" }) == null);
    try std.testing.expect(mapPiTitle(&buffer, .{ .event = "agent_start", .name = "Fix proxy" }) == null);
    try std.testing.expect(mapPiHook(.{ .event = "session_info_changed", .name = "Fix proxy" }) == null);

    const long = "é" ** 60;
    const cut = mapPiTitle(&buffer, .{ .event = "session_info_changed", .name = long }).?;
    try std.testing.expectEqual(@as(usize, 96), cut.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));
}

test "Pi hook JSON accepts the extension payload" {
    const parsed = try std.json.parseFromSlice(PiHookInput, std.testing.allocator, "{\"event\":\"session_start\",\"session_id\":\"01a061a3-a2e7-7574-9e07-997b8d59340d\",\"idle\":true}", .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const report = mapPiHook(parsed.value).?;
    try std.testing.expectEqual(core.AgentReportState.ready, report.state);
    try std.testing.expectEqualStrings("01a061a3-a2e7-7574-9e07-997b8d59340d", report.session);
    try std.testing.expectError(error.SyntaxError, std.json.parseFromSlice(PiHookInput, std.testing.allocator, "not json", .{ .ignore_unknown_fields = true }));
}

test "Claude session titles and transcripts ride along with the hook reports" {
    var event_buffer: hook_event.Buffer = undefined;
    var buffer: [core.max_agent_session_title_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("Fix proxy", mapClaudeTitle(&buffer, .{ .hook_event_name = "SessionStart", .session_title = "Fix proxy" }).?);
    try std.testing.expect(mapClaudeTitle(&buffer, .{ .hook_event_name = "SessionStart" }) == null);
    try std.testing.expect(mapClaudeTitle(&buffer, .{ .hook_event_name = "Stop", .session_title = "Fix proxy" }) == null);
    try std.testing.expect(mapClaudeTitle(&buffer, .{ .hook_event_name = "SessionStart", .session_title = "Fix proxy", .agent_id = "sub-1" }) == null);

    const report = mapClaudeHook(.{ .hook_event_name = "Stop", .transcript_path = "/home/me/.claude/projects/p/s.jsonl" }, &event_buffer).?;
    try std.testing.expectEqualStrings("/home/me/.claude/projects/p/s.jsonl", report.session_file);
    try std.testing.expectEqual(core.AgentSessionFileKind.claude_transcript, report.session_file_kind);
    const long = "/" ** (core.max_agent_session_file_bytes + 1);
    try std.testing.expectEqualStrings("", mapClaudeHook(.{ .hook_event_name = "Stop", .transcript_path = long }, &event_buffer).?.session_file);
    try std.testing.expectEqualStrings("", mapCodexHook(.{ .hook_event_name = "Stop" }, &event_buffer).?.session_file);
}

test "Codex reports carry the resolved state database and find the newest schema" {
    var event_buffer: hook_event.Buffer = undefined;
    const report = mapCodexHook(.{ .hook_event_name = "Stop", .state_database = "/home/me/.codex/state_5.sqlite" }, &event_buffer).?;
    try std.testing.expectEqualStrings("/home/me/.codex/state_5.sqlite", report.session_file);
    try std.testing.expectEqual(core.AgentSessionFileKind.codex_state, report.session_file_kind);
    try std.testing.expectEqual(core.AgentSessionFileKind.codex_state, mapCodexHook(.{ .hook_event_name = "SessionEnd", .state_database = "/x" }, &event_buffer).?.session_file_kind);

    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = directory_buffer[0..try temp.dir.realPath(io, &directory_buffer)];
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expect(codexStateDatabase(io, directory, &buffer) == null);

    try temp.dir.writeFile(io, .{ .sub_path = "state_5.sqlite", .data = "" });
    try temp.dir.writeFile(io, .{ .sub_path = "state_12.sqlite", .data = "" });
    try temp.dir.writeFile(io, .{ .sub_path = "state_12.sqlite-wal", .data = "" });
    try temp.dir.writeFile(io, .{ .sub_path = "logs_2.sqlite", .data = "" });
    const found = codexStateDatabase(io, directory, &buffer).?;
    try std.testing.expect(std.mem.endsWith(u8, found, "/state_12.sqlite"));
    try std.testing.expect(std.mem.startsWith(u8, found, directory));

    var missing_buffer: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expect(codexStateDatabase(io, "/nonexistent/telar", &missing_buffer) == null);
}

test "Claude hook events map to reports and subagent lifecycle events are ignored" {
    var buffer: hook_event.Buffer = undefined;
    const session = "0192aaaa-bbbb-cccc-dddd-eeeeffff0000";
    const start = mapClaudeHook(.{ .hook_event_name = "SessionStart", .session_id = session }, &buffer).?;
    try std.testing.expectEqual(core.AgentReportState.ready, start.state);
    try std.testing.expectEqualStrings(session, start.session);
    try std.testing.expectEqual(core.AgentReportState.working, mapClaudeHook(.{ .hook_event_name = "UserPromptSubmit" }, &buffer).?.state);
    try std.testing.expectEqual(core.AgentReportState.ready, mapClaudeHook(.{ .hook_event_name = "Stop" }, &buffer).?.state);
    try std.testing.expectEqual(core.AgentReportState.exited, mapClaudeHook(.{ .hook_event_name = "SessionEnd" }, &buffer).?.state);
    try std.testing.expectEqual(core.AgentReportState.blocked, mapClaudeHook(.{ .hook_event_name = "Notification", .notification_type = "permission_prompt" }, &buffer).?.state);
    try std.testing.expectEqual(core.AgentReportState.idle, mapClaudeHook(.{ .hook_event_name = "Notification", .notification_type = "idle_prompt" }, &buffer).?.state);
    try std.testing.expect(mapClaudeHook(.{ .hook_event_name = "Notification", .notification_type = "auth_success" }, &buffer) == null);
    try std.testing.expectEqual(core.AgentReportState.working, mapClaudeHook(.{ .hook_event_name = "PreToolUse" }, &buffer).?.state);
    try std.testing.expect(mapClaudeHook(.{ .hook_event_name = "Stop", .agent_id = "sub-1" }, &buffer) == null);
    try std.testing.expectEqualStrings("", mapClaudeHook(.{ .hook_event_name = "Stop", .session_id = "bad session" }, &buffer).?.session);
}

test "a Claude Stop that leaves subagents running reports a wait" {
    var buffer: hook_event.Buffer = undefined;
    const waiting = mapClaudeHook(
        .{
            .hook_event_name = "Stop",
            .last_assistant_message = "The agents are still working.",
            .background_tasks = &.{
                .{ .type = "subagent", .status = "running" },
                .{ .type = "shell", .status = "running" },
                .{ .type = "subagent", .status = "running" },
            },
        },
        &buffer,
    ).?;
    try std.testing.expectEqual(core.AgentReportState.waiting, waiting.state);
    try std.testing.expectEqualStrings("waiting for 2 background agents", waiting.event);

    const one = mapClaudeHook(
        .{
            .hook_event_name = "Stop",
            .background_tasks = &.{
                .{ .type = "subagent", .status = "running" },
                .{ .type = "subagent", .status = "completed" },
            },
        },
        &buffer,
    ).?;
    try std.testing.expectEqualStrings("waiting for 1 background agent", one.event);

    const shell_only = mapClaudeHook(
        .{
            .hook_event_name = "Stop",
            .last_assistant_message = "Dev server is up.",
            .background_tasks = &.{
                .{ .type = "shell", .status = "running" },
            },
        },
        &buffer,
    ).?;
    try std.testing.expectEqual(core.AgentReportState.ready, shell_only.state);
    try std.testing.expectEqualStrings("Dev server is up.", shell_only.event);
}

test "Claude subagent tool calls renew work and nothing else" {
    var buffer: hook_event.Buffer = undefined;
    const renewal = mapClaudeHook(.{ .hook_event_name = "PreToolUse", .agent_id = "sub-1", .tool_name = "Bash", .session_id = "0192aaaa-bbbb-cccc-dddd-eeeeffff0000" }, &buffer).?;
    try std.testing.expectEqual(core.AgentReportState.continuing, renewal.state);
    try std.testing.expectEqualStrings("", renewal.session);
    try std.testing.expectEqualStrings("", renewal.event);
    try std.testing.expectEqual(core.AgentReportState.continuing, mapClaudeHook(.{ .hook_event_name = "PostToolUse", .agent_id = "sub-1" }, &buffer).?.state);
    try std.testing.expect(mapClaudeHook(.{ .hook_event_name = "Notification", .notification_type = "permission_prompt", .agent_id = "sub-1" }, &buffer) == null);
    try std.testing.expect(mapClaudeHook(.{ .hook_event_name = "SubagentStop", .agent_id = "sub-1" }, &buffer) == null);
}

test "the background tasks of a real Claude Stop payload are read" {
    const payload =
        \\{"session_id":"0b4d1d8f-d094-4b86-8a23-7cbee8e2ca13","hook_event_name":"Stop","stop_hook_active":false,
        \\"background_tasks":[{"id":"aef142ba64a0794f5","type":"subagent","status":"running","description":"Sleep test","agent_type":"general-purpose"},
        \\{"id":"bgt6cv25t","type":"shell","status":"running","description":"Sleep","command":"sleep 25"}],"session_crons":[]}
    ;
    const parsed = try std.json.parseFromSlice(ClaudeHookInput, std.testing.allocator, payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.runningSubagents());

    const bare = try std.json.parseFromSlice(ClaudeHookInput, std.testing.allocator, "{\"hook_event_name\":\"Stop\"}", .{ .ignore_unknown_fields = true });
    defer bare.deinit();
    try std.testing.expectEqual(@as(usize, 0), bare.value.runningSubagents());
}

test "Codex hook events map to reports" {
    var buffer: hook_event.Buffer = undefined;
    const session = "0192aaaa-bbbb-cccc-dddd-eeeeffff0000";
    const start = mapCodexHook(.{ .hook_event_name = "SessionStart", .session_id = session }, &buffer).?;
    try std.testing.expectEqual(core.AgentReportState.ready, start.state);
    try std.testing.expectEqualStrings(session, start.session);
    try std.testing.expectEqual(core.AgentReportState.working, mapCodexHook(.{ .hook_event_name = "SessionStart", .source = "compact" }, &buffer).?.state);
    try std.testing.expectEqual(core.AgentReportState.working, mapCodexHook(.{ .hook_event_name = "UserPromptSubmit" }, &buffer).?.state);
    try std.testing.expectEqual(core.AgentReportState.blocked, mapCodexHook(.{ .hook_event_name = "PermissionRequest" }, &buffer).?.state);
    try std.testing.expectEqual(core.AgentReportState.working, mapCodexHook(.{ .hook_event_name = "PostToolUse" }, &buffer).?.state);
    try std.testing.expectEqual(core.AgentReportState.settling, mapCodexHook(.{ .hook_event_name = "Stop" }, &buffer).?.state);
    try std.testing.expectEqual(core.AgentReportState.ready, mapCodexHook(.{ .hook_event_name = "Interrupt" }, &buffer).?.state);
    try std.testing.expectEqual(core.AgentReportState.exited, mapCodexHook(.{ .hook_event_name = "SessionEnd" }, &buffer).?.state);
    try std.testing.expectEqual(core.AgentReportState.working, mapCodexHook(.{ .hook_event_name = "PreToolUse" }, &buffer).?.state);
    try std.testing.expectEqualStrings("", mapCodexHook(.{ .hook_event_name = "Stop", .session_id = "bad session" }, &buffer).?.session);
}

test "Codex subagents keep a finished turn waiting until the last one stops" {
    var buffer: hook_event.Buffer = undefined;
    const session = "01a0dcd0-a558-74a1-a3ad-0198c1715d1f";
    const rollout = "/home/me/.codex/sessions/2026/09/26/rollout-2026-09-26T10-24-16-01a0dcd0-a558-74a1-a3ad-0198c1715d1f.jsonl";
    const waiting = mapCodexHook(.{ .hook_event_name = "Stop", .session_id = session, .transcript_path = rollout, .running_subagents = 2 }, &buffer).?;
    try std.testing.expectEqual(core.AgentReportState.waiting, waiting.state);
    try std.testing.expectEqualStrings("waiting for 2 background agents", waiting.event);
    try std.testing.expectEqual(core.AgentReportState.waiting, mapCodexHook(.{ .hook_event_name = "Interrupt", .running_subagents = 1 }, &buffer).?.state);

    const child = "01a0dcd1-0be8-73f0-b8d7-9b50638143ca";
    try std.testing.expectEqual(core.AgentReportState.continuing, mapCodexHook(.{ .hook_event_name = "PostToolUse", .agent_id = child }, &buffer).?.state);
    try std.testing.expect(mapCodexHook(.{ .hook_event_name = "SubagentStart", .agent_id = child }, &buffer) == null);
    try std.testing.expect(mapCodexHook(.{ .hook_event_name = "PermissionRequest", .agent_id = child }, &buffer) == null);
    try std.testing.expect(mapCodexHook(.{ .hook_event_name = "SubagentStop", .agent_id = child, .session_id = session, .transcript_path = rollout, .running_subagents = 1 }, &buffer) == null);
    try std.testing.expectEqual(core.AgentReportState.released, mapCodexHook(.{ .hook_event_name = "SubagentStop", .agent_id = child, .session_id = session, .transcript_path = rollout }, &buffer).?.state);

    // A nested child's stop reads its parent's rollout, not the session's.
    const nested = "/home/me/.codex/sessions/2026/09/26/rollout-2026-09-26T10-24-42-01a0dcd1-0be8-73f0-b8d7-9b50638143ca.jsonl";
    try std.testing.expect(mapCodexHook(.{ .hook_event_name = "SubagentStop", .agent_id = "grandchild", .session_id = session, .transcript_path = nested }, &buffer) == null);
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
    try std.testing.expectEqual(core.AgentCommandPhase.started, codex_command.phase);
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
    try std.testing.expectEqual(core.AgentCommandPhase.finished, claude_command.phase);
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

test "Pi snapshots preserve active runs and nested prompts" {
    try std.testing.expectEqual(core.AgentReportState.working, mapPiHook(.{ .event = "state_snapshot", .idle = false }).?.state);
    try std.testing.expectEqual(core.AgentReportState.ready, mapPiHook(.{ .event = "state_snapshot", .idle = true }).?.state);
    try std.testing.expectEqual(core.AgentReportState.blocked, mapPiHook(.{ .event = "ui_prompt_end", .idle = true, .blocked = true }).?.state);
    try std.testing.expectEqual(core.AgentReportState.working, mapPiHook(.{ .event = "agent_settled", .idle = false }).?.state);
    try std.testing.expectEqual(core.AgentReportState.working, mapPiHook(.{ .event = "session_start", .idle = false }).?.state);
}

test "Claude prompts and tool calls name their reason and event line" {
    var buffer: hook_event.Buffer = undefined;
    const permission = mapClaudeHook(.{ .hook_event_name = "Notification", .notification_type = "permission_prompt", .message = "Claude needs your permission to use Bash" }, &buffer).?;
    try std.testing.expectEqual(core.AgentReportState.blocked, permission.state);
    try std.testing.expectEqual(core.AgentBlockedReason.permission, permission.blocked_reason);
    try std.testing.expectEqualStrings("Claude needs your permission to use Bash", permission.event);

    const asking = mapClaudeHook(.{ .hook_event_name = "Notification", .notification_type = "elicitation_dialog", .message = "Pick one" }, &buffer).?;
    try std.testing.expectEqual(core.AgentBlockedReason.question, asking.blocked_reason);
    try std.testing.expectEqualStrings("Pick one", asking.event);

    const edit = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"file_path\":\"src/client/bars/Output.zig\"}", .{});
    defer edit.deinit();
    const working = mapClaudeHook(.{ .hook_event_name = "PreToolUse", .tool_name = "Edit", .tool_input = edit.value }, &buffer).?;
    try std.testing.expectEqual(core.AgentReportState.working, working.state);
    try std.testing.expectEqual(core.AgentBlockedReason.none, working.blocked_reason);
    try std.testing.expectEqualStrings("» Edit src/client/bars/Output.zig", working.event);

    const asked = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"questions\":[{\"question\":\"Which database?\"}]}", .{});
    defer asked.deinit();
    const question = mapClaudeHook(.{ .hook_event_name = "PreToolUse", .tool_name = "AskUserQuestion", .tool_input = asked.value }, &buffer).?;
    try std.testing.expectEqual(core.AgentReportState.blocked, question.state);
    try std.testing.expectEqual(core.AgentBlockedReason.question, question.blocked_reason);
    try std.testing.expectEqualStrings("Which database?", question.event);

    const plan = mapClaudeHook(.{ .hook_event_name = "PreToolUse", .tool_name = "ExitPlanMode" }, &buffer).?;
    try std.testing.expectEqual(core.AgentBlockedReason.plan, plan.blocked_reason);
    try std.testing.expectEqualStrings("» ExitPlanMode", plan.event);

    const stop = mapClaudeHook(.{ .hook_event_name = "Stop", .last_assistant_message = "Done: tests pass.\nDetails follow." }, &buffer).?;
    try std.testing.expectEqual(core.AgentBlockedReason.none, stop.blocked_reason);
    try std.testing.expectEqualStrings("Done: tests pass.", stop.event);
}

test "Codex permission requests and tool events name their tool call" {
    var buffer: hook_event.Buffer = undefined;
    const input = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"command\":\"zig build test\"}", .{});
    defer input.deinit();
    const permission = mapCodexHook(.{ .hook_event_name = "PermissionRequest", .tool_name = "Bash", .tool_input = input.value }, &buffer).?;
    try std.testing.expectEqual(core.AgentBlockedReason.permission, permission.blocked_reason);
    try std.testing.expectEqualStrings("» Bash zig build test", permission.event);

    const working = mapCodexHook(.{ .hook_event_name = "PostToolUse", .tool_name = "Bash", .tool_input = input.value }, &buffer).?;
    try std.testing.expectEqual(core.AgentBlockedReason.none, working.blocked_reason);
    try std.testing.expectEqualStrings("» Bash zig build test", working.event);
    try std.testing.expectEqualStrings("", mapCodexHook(.{ .hook_event_name = "UserPromptSubmit" }, &buffer).?.event);
}

test "Pi dialogs are questions" {
    try std.testing.expectEqual(core.AgentBlockedReason.question, mapPiHook(.{ .event = "ui_prompt_start" }).?.blocked_reason);
    try std.testing.expectEqual(core.AgentBlockedReason.question, mapPiHook(.{ .event = "state_snapshot", .blocked = true }).?.blocked_reason);
    try std.testing.expectEqual(core.AgentBlockedReason.none, mapPiHook(.{ .event = "agent_start" }).?.blocked_reason);
}
