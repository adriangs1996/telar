//! `telar hook <agent>`: the command an agent's lifecycle hooks run. It
//! reads the hook's JSON from stdin, maps the event to one official report
//! and sends it to the runtime that owns the pane. `TELAR_PANE_ID` only
//! names the pane: the hook reports only after the runtime confirms that
//! its chain of parent processes reaches that pane, because a process that
//! left the pane, such as a shared server started there, inherits the same
//! variable. It never fails loudly: outside a telar pane, from a process
//! that left it, or on any error, it exits 0 so the agent is unaffected.

const core = @import("telar-core");
const ToolHookInput = @import("ToolHookInput.zig");
const CommandReport = @import("CommandReport.zig");
const AgentCommandReport = @import("AgentCommandReport.zig");
const std = @import("std");
const PiHookInput = @import("PiHookInput.zig");
const Report = @import("Report.zig");
const ClaudeHookInput = @import("ClaudeHookInput.zig");
const CodexHookInput = @import("CodexHookInput.zig");
const CursorHookInput = @import("CursorHookInput.zig");
const OpenCodeHookInput = @import("OpenCodeHookInput.zig");
const HookOptions = @import("arguments/HookOptions.zig");
const control = @import("control.zig");
const Target = @import("Target.zig");
const Reports = @import("Reports.zig");
const Session = @import("Session.zig");
const hook_event = @import("hook_event.zig");
const hook_progress = @import("hook_progress.zig");
const hook_worktree = @import("hook_worktree.zig");
const ProgressStorage = @import("ProgressStorage.zig");
const WorktreeHookInput = @import("WorktreeHookInput.zig");
const CodexSubagents = @import("CodexSubagents.zig");
const agentfiles = @import("agentfiles");
const HookStdin = @import("HookStdin.zig");
const limit_reached = @import("limit_reached.zig");

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
        std.mem.eql(u8, input.event, "tool_execution_start") or
        std.mem.eql(u8, input.event, "tool.execute.before"))
        .started
    else if (std.mem.eql(u8, input.event, "PostToolUse") or
        std.mem.eql(u8, input.event, "tool_execution_end") or
        std.mem.eql(u8, input.event, "tool.execute.after"))
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

/// Maps one event of the OpenCode plugin to a report. The plugin keeps the
/// pane state OpenCode implies: a busy root session works, an open
/// permission or question blocks, and an idle one is ready, including after
/// an interrupt. Every report under an open prompt names that prompt in
/// `buffer`, and a tool call names itself, but a tool call under an open
/// prompt reports nothing; the last plugin instance to be disposed reports
/// the exit.
///
/// ```zig
/// const report = mapOpenCodeHook(input, &buffer) orelse return;
/// ```
pub fn mapOpenCodeHook(input: OpenCodeHookInput, buffer: *hook_event.Buffer) ?Report {
    const event = input.event;
    const session = if (core.validateSessionReference(input.session_id)) |_| input.session_id else |_| "";

    if (std.mem.eql(u8, event, "tool.execute.before")) {
        // A call that starts while another call's prompt is open leaves
        // that prompt, and its event line, in place.
        if (input.blocked != .none) {
            return null;
        }

        return .{
            .state = .working,
            .event = hook_event.toolCall(buffer, input.tool_name, input.tool_input) orelse "",
            .session = session,
        };
    }

    if (std.mem.eql(u8, event, "load") or
        std.mem.eql(u8, event, "chat.message") or
        std.mem.eql(u8, event, "session.status") or
        std.mem.eql(u8, event, "permission.asked") or
        std.mem.eql(u8, event, "question.asked") or
        std.mem.eql(u8, event, "permission.replied") or
        std.mem.eql(u8, event, "question.replied") or
        std.mem.eql(u8, event, "question.rejected") or
        std.mem.eql(u8, event, "state_snapshot"))
    {
        if (input.blocked != .none) {
            return .{
                .state = .blocked,
                .blocked_reason = input.blocked,
                .event = openCodePromptLine(buffer, input),
                .session = session,
            };
        }

        return .{
            .state = if (input.busy) .working else .ready,
            .session = session,
        };
    }

    if (std.mem.eql(u8, event, "dispose")) {
        return .{
            .state = .exited,
        };
    }

    return null;
}

/// The event line of the prompt a plugin report carries: the permission's
/// request or the first question.
fn openCodePromptLine(buffer: *hook_event.Buffer, input: OpenCodeHookInput) []const u8 {
    return switch (input.blocked) {
        .permission => hook_event.toolCall(buffer, input.tool_name, input.tool_input) orelse "",
        .question => hook_event.question(buffer, input.tool_input) orelse "",
        .none, .plan, .other => "",
    };
}

/// Maps the root session's title to a title report. OpenCode names every
/// session `New session - <ISO time>` until the user renames it or its
/// title agent names it, so that default clears the title instead.
///
/// ```zig
/// const title = mapOpenCodeTitle(&buffer, input) orelse return;
/// ```
pub fn mapOpenCodeTitle(buffer: *[core.max_agent_session_title_bytes]u8, input: OpenCodeHookInput) ?[]const u8 {
    if (!std.mem.eql(u8, input.event, "session.updated")) {
        return null;
    }

    const title = input.title orelse return null;
    if (isOpenCodeDefaultTitle(title)) {
        return "";
    }

    return core.truncateSessionTitle(buffer, title);
}

/// OpenCode's `isDefaultTitle`: a prefix and the creation time as
/// `toISOString` writes it, where `0` stands for any digit.
fn isOpenCodeDefaultTitle(title: []const u8) bool {
    const time_shape = "0000-00-00T00:00:00.000Z";

    for ([_][]const u8{ "New session - ", "Child session - " }) |prefix| {
        if (title.len != prefix.len + time_shape.len or !std.mem.startsWith(u8, title, prefix)) {
            continue;
        }

        for (title[prefix.len..], time_shape) |byte, shape| {
            const matches = if (shape == '0') std.ascii.isDigit(byte) else byte == shape;
            if (!matches) {
                return false;
            }
        }

        return true;
    }

    return false;
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
    const settings = core.HookSettings.codex;
    const override = if (settings.environment()) |name| std.process.Environ.getPosix(environ, name) else null;
    return settings.directory(
        override,
        std.process.Environ.getPosix(environ, "HOME"),
        buffer,
    );
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

/// Maps one Cursor Agent hook event to a report. Cursor fires no hook for
/// a command approval or a plan review; those reach the runtime from the
/// screen. Every turn end reports `ready`, including the `aborted` and
/// `error` stops an interrupt fires. Tool events name their call in
/// `buffer`.
///
/// ```zig
/// const report = mapCursorHook(input, &buffer) orelse return;
/// ```
pub fn mapCursorHook(input: CursorHookInput, buffer: *hook_event.Buffer) ?Report {
    const event = input.hook_event_name;
    const session = if (core.validateSessionReference(input.conversation_id)) |_| input.conversation_id else |_| "";
    const file = if (input.chat_meta.len <= core.max_agent_session_file_bytes) input.chat_meta else "";

    if (std.mem.eql(u8, event, "sessionStart") or std.mem.eql(u8, event, "stop")) {
        return .{ .state = .ready, .session = session, .session_file = file, .session_file_kind = .cursor_meta };
    }
    if (std.mem.eql(u8, event, "beforeSubmitPrompt")) {
        return .{ .state = .working, .session = session, .session_file = file, .session_file_kind = .cursor_meta };
    }
    if (input.toolEvent() != null) {
        const call = hook_event.toolCall(buffer, input.tool_name, input.tool_input) orelse "";
        return .{ .state = .working, .event = call, .session = session, .session_file = file, .session_file_kind = .cursor_meta };
    }
    if (std.mem.eql(u8, event, "sessionEnd")) {
        return .{ .state = .exited, .session_file = file, .session_file_kind = .cursor_meta };
    }

    return null;
}

/// Finds the chat metadata Cursor rewrites on `/rename`. Only the events
/// that open a session or a turn look: a resumed chat fires no
/// `sessionStart`, and a tool call never waits on the lookup.
fn cursorChatMeta(init: std.process.Init, input: *const CursorHookInput, buffer: *[std.fs.max_path_bytes]u8) []const u8 {
    if (!std.mem.eql(u8, input.hook_event_name, "sessionStart") and !std.mem.eql(u8, input.hook_event_name, "beforeSubmitPrompt")) {
        return "";
    }

    const environ = init.minimal.environ;
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = agentfiles.cursor.configDirectory(
        std.process.Environ.getPosix(environ, "CURSOR_CONFIG_DIR"),
        std.process.Environ.getPosix(environ, "XDG_CONFIG_HOME"),
        std.process.Environ.getPosix(environ, "HOME"),
        &root_buffer,
    ) orelse return "";
    return agentfiles.cursor.locate(init.io, root, input.workspace(), input.conversation_id, buffer) orelse "";
}

/// Runs the hook for `options.agent`. Lifecycle hooks always exit 0 and
/// do nothing outside a telar pane. Claude Code's worktree hooks run
/// everywhere and fail loudly, because Claude Code uses their answer.
///
/// ```zig
/// try hook.run(process_init, options);
/// ```
pub fn run(init: std.process.Init, options: HookOptions) !void {
    const environ = init.minimal.environ;
    var stdin = HookStdin.read(init) catch return;
    defer stdin.deinit(init.gpa);
    // Every way out says the input passed its limit, the early ones too;
    // `sendReports` also reports it to the runtime.
    defer {
        if (stdin.limit) |reach| {
            limit_reached.report(reach);
        }
    }
    const input = stdin.text;

    if (options.agent == .claude) {
        const worktree_hook = std.json.parseFromSlice(WorktreeHookInput, init.gpa, input, .{ .ignore_unknown_fields = true }) catch null;
        if (worktree_hook) |parsed| {
            defer parsed.deinit();
            if (hook_worktree.handles(parsed.value.hook_event_name)) {
                hook_worktree.answer(init, parsed.value, options.socket) catch |err| {
                    if (stdin.limit) |reach| {
                        limit_reached.report(reach);
                    }

                    // This is the command failure diagnostic on stderr; keep its CLI prefix and leave stdout available for results.
                    std.debug.print("telar hook: {s} failed: {s}\n", .{ parsed.value.hook_event_name, control.describe(err) });
                    std.process.exit(1);
                };
                return;
            }
        }
    }

    const pane_id = control.currentPaneId(environ) catch return;
    const generation_text = std.process.Environ.getPosix(environ, "TELAR_PANE_GENERATION") orelse return;
    const pane_generation = std.fmt.parseUnsigned(u64, generation_text, 10) catch return;
    const target: Target = .{
        .socket = options.socket,
        .pane = .{ .pane_id = pane_id, .pane_generation = pane_generation },
        .provider = hookProvider(options.agent),
    };
    switch (options.agent) {
        .claude => {
            const parsed = std.json.parseFromSlice(ClaudeHookInput, init.gpa, input, .{ .ignore_unknown_fields = true }) catch return;
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
            // SAFETY: Hook formatting writes the event prefix before returning its slice; absent events do not read the buffer.
            var event_buffer: hook_event.Buffer = undefined;
            var progress_storage: ProgressStorage = .{};
            sendReports(init, target, .{
                .limit = stdin.limit,
                .lifecycle = mapClaudeHook(parsed.value, &event_buffer),
                .command = command,
                .title = mapClaudeTitle(&title_buffer, parsed.value),
                .progress = hook_progress.map(init.io, .{
                    .event = parsed.value.hook_event_name,
                    .agent_id = parsed.value.agent_id,
                    .tool_name = parsed.value.tool_name,
                    .tool_input = parsed.value.tool_input,
                    .cwd = parsed.value.cwd,
                    .new_cwd = parsed.value.new_cwd,
                    .last_assistant_message = parsed.value.last_assistant_message,
                }, &progress_storage),
            });
        },
        .codex => {
            var parsed = std.json.parseFromSlice(CodexHookInput, init.gpa, input, .{ .ignore_unknown_fields = true }) catch return;
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
            // SAFETY: Hook formatting writes the event prefix before returning its slice; absent events do not read the buffer.
            var event_buffer: hook_event.Buffer = undefined;
            var progress_storage: ProgressStorage = .{};
            sendReports(init, target, .{
                .limit = stdin.limit,
                .lifecycle = mapCodexHook(parsed.value, &event_buffer),
                .command = command,
                .progress = hook_progress.map(init.io, .{
                    .event = parsed.value.hook_event_name,
                    .agent_id = parsed.value.agent_id,
                    .tool_name = parsed.value.tool_name,
                    .tool_input = parsed.value.tool_input,
                    .cwd = parsed.value.cwd,
                    .last_assistant_message = parsed.value.last_assistant_message orelse "",
                }, &progress_storage),
            });
        },
        .pi => {
            const parsed = std.json.parseFromSlice(PiHookInput, init.gpa, input, .{ .ignore_unknown_fields = true }) catch return;
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
                .limit = stdin.limit,
                .lifecycle = mapPiHook(parsed.value),
                .command = command,
                .title = mapPiTitle(&title_buffer, parsed.value),
            });
        },
        .opencode => {
            const parsed = std.json.parseFromSlice(OpenCodeHookInput, init.gpa, input, .{ .ignore_unknown_fields = true }) catch return;
            defer parsed.deinit();
            const command = mapToolCommand(.opencode, .{
                .event = parsed.value.event,
                .tool_name = parsed.value.tool_name,
                .tool_call_id = parsed.value.tool_call_id,
                .tool_input = parsed.value.tool_input,
                .cwd = parsed.value.cwd,
                .session = parsed.value.session_id,
                .exit_code = parsed.value.exit_code,
            });
            var title_buffer: [core.max_agent_session_title_bytes]u8 = undefined;
            // SAFETY: Hook formatting writes the event prefix before returning its slice; absent events do not read the buffer.
            var event_buffer: hook_event.Buffer = undefined;
            sendReports(init, target, .{
                .limit = stdin.limit,
                .lifecycle = mapOpenCodeHook(parsed.value, &event_buffer),
                .command = command,
                .title = mapOpenCodeTitle(&title_buffer, parsed.value),
            });
        },
        .cursor => {
            var parsed = std.json.parseFromSlice(CursorHookInput, init.gpa, input, .{ .ignore_unknown_fields = true }) catch return;
            defer parsed.deinit();
            var meta_buffer: [std.fs.max_path_bytes]u8 = undefined;
            parsed.value.chat_meta = cursorChatMeta(init, &parsed.value, &meta_buffer);
            const tool: ToolHookInput = .{
                .event = parsed.value.toolEvent() orelse parsed.value.hook_event_name,
                .tool_name = parsed.value.tool_name,
                .tool_call_id = parsed.value.tool_use_id,
                .tool_input = parsed.value.tool_input,
                .cwd = parsed.value.shellDirectory(),
                .session = parsed.value.conversation_id,
                .exit_code = parsed.value.shellExitCode(),
            };
            // SAFETY: Hook formatting writes the event prefix before returning its slice; absent events do not read the buffer.
            var event_buffer: hook_event.Buffer = undefined;
            sendReports(init, target, .{
                .limit = stdin.limit,
                .lifecycle = mapCursorHook(parsed.value, &event_buffer),
                .command = mapToolCommand(.cursor, tool),
            });
        },
    }
}

fn hookProvider(agent: HookOptions.Agent) core.AgentProvider {
    return switch (agent) {
        .claude => .claude,
        .codex => .codex,
        .pi => .pi,
        .cursor => .cursor,
        .opencode => .opencode,
    };
}

/// Sends every report the event produced. Each is independent of the ones
/// before it, so one the runtime refuses never costs the others, and a
/// limit the input reached is sent last; `run` prints it.
fn sendReports(init: std.process.Init, target: Target, reports: Reports) void {
    if (reports.lifecycle == null and reports.command == null and reports.title == null and reports.progress == null) {
        return;
    }

    // Attach only. The pane environment survives a stopped runtime, and a
    // hook that started one would resurrect it from every orphaned agent.
    var session = Session.attach(init, target.socket) catch return;
    defer session.close();

    const pane = target.pane;
    session.verifyDescent(pane) catch return;
    sendVerified(&session, target, reports);
    if (reports.limit) |reach| {
        // Hook observations are best effort so an unavailable runtime cannot fail the agent hook.
        session.reportLimit(reach) catch {};
    }
}

fn sendVerified(session: *Session, target: Target, reports: Reports) void {
    const pane = target.pane;

    // Progress goes first: a final answer is stored before the lifecycle
    // report marks the turn finished, so a waiter never reads a stale one.
    if (reports.progress) |progress| {
        var report = progress;
        report.pane_id = core.pane(pane.pane_id) catch return;
        report.pane_generation = pane.pane_generation;
        report.provider = target.provider;
        // Progress is an observation; failure to report it must not interrupt the agent hook.
        session.reportProgress(report) catch {};
    }

    if (reports.lifecycle) |lifecycle| {
        const report: Session.AgentReport = .{
            .provider = target.provider,
            .state = lifecycle.state,
            .blocked_reason = lifecycle.blocked_reason,
            .event = lifecycle.event,
            .session = lifecycle.session,
            .session_file = lifecycle.session_file,
            .session_file_kind = lifecycle.session_file_kind,
        };
        // Lifecycle reporting is best effort; the hook must not fail the running agent when the runtime disconnects.
        session.reportAgent(pane, report) catch {};
    }

    if (reports.title) |title| {
        // A title update is optional observation data and must not fail the agent hook.
        session.reportAgentTitle(pane, target.provider, title) catch {};
    }

    if (reports.command) |tool| {
        const command: AgentCommandReport = .{
            .phase = tool.phase,
            .provider = tool.provider,
            .tool_call_id = tool.tool_call_id,
            .command = tool.command,
            .cwd = tool.cwd,
            .session = tool.session,
            .exit_code = tool.exit_code,
        };
        // Command observations are best effort and cannot hold up the agent on runtime failure.
        session.reportAgentCommand(pane, command) catch {};
    }
}
