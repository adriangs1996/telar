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
        session.reportAgent(pane, report) catch {};
    }

    if (reports.title) |title| {
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
        session.reportAgentCommand(pane, command) catch {};
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

test "Cursor hook events map to reports and every turn end settles" {
    var buffer: hook_event.Buffer = undefined;
    const chat = "7f8ca51a-88f1-40a0-a73f-0f180d035134";
    const meta = "/home/me/.cursor/chats/8ab1766528a4f5793554c6ceee08b55b/" ++ chat ++ "/meta.json";

    const start = mapCursorHook(.{ .hook_event_name = "sessionStart", .conversation_id = chat, .chat_meta = meta }, &buffer).?;
    try std.testing.expectEqual(core.AgentReportState.ready, start.state);
    try std.testing.expectEqualStrings(chat, start.session);
    try std.testing.expectEqualStrings(meta, start.session_file);
    try std.testing.expectEqual(core.AgentSessionFileKind.cursor_meta, start.session_file_kind);

    try std.testing.expectEqual(core.AgentReportState.working, mapCursorHook(.{ .hook_event_name = "beforeSubmitPrompt", .conversation_id = chat }, &buffer).?.state);
    for ([_][]const u8{ "completed", "aborted", "error" }) |_| {
        try std.testing.expectEqual(core.AgentReportState.ready, mapCursorHook(.{ .hook_event_name = "stop", .conversation_id = chat }, &buffer).?.state);
    }
    try std.testing.expectEqual(core.AgentReportState.exited, mapCursorHook(.{ .hook_event_name = "sessionEnd", .conversation_id = chat }, &buffer).?.state);
    try std.testing.expect(mapCursorHook(.{ .hook_event_name = "afterAgentThought", .conversation_id = chat }, &buffer) == null);
    try std.testing.expect(mapCursorHook(.{ .hook_event_name = "beforeShellExecution", .conversation_id = chat }, &buffer) == null);
    try std.testing.expectEqualStrings("", mapCursorHook(.{ .hook_event_name = "stop", .conversation_id = "../etc" }, &buffer).?.session);
}

test "Cursor hook JSON maps a Shell call to a working report and a command row with its exit code" {
    const pre_source =
        \\{"conversation_id":"7f8ca51a-88f1-40a0-a73f-0f180d035134","generation_id":"x","model":"default","tool_name":"Shell",
        \\"tool_input":{"command":"touch created.txt && echo made","cwd":"","timeout":30000},"tool_use_id":"0b10deac-f115-4905-ab27-ed0fd5d14461",
        \\"cwd":"","session_id":"7f8ca51a-88f1-40a0-a73f-0f180d035134","hook_event_name":"preToolUse","cursor_version":"2026.09.26-dd393fe",
        \\"workspace_roots":["/work/proj"],"user_email":"me@example.com","transcript_path":null}
    ;
    const pre = try std.json.parseFromSlice(CursorHookInput, std.testing.allocator, pre_source, .{ .ignore_unknown_fields = true });
    defer pre.deinit();
    var buffer: hook_event.Buffer = undefined;
    const report = mapCursorHook(pre.value, &buffer).?;
    try std.testing.expectEqual(core.AgentReportState.working, report.state);
    try std.testing.expectEqualStrings("» Shell touch created.txt && echo made", report.event);

    const started = mapToolCommand(.cursor, .{
        .event = pre.value.toolEvent().?,
        .tool_name = pre.value.tool_name,
        .tool_call_id = pre.value.tool_use_id,
        .tool_input = pre.value.tool_input,
        .cwd = pre.value.shellDirectory(),
        .session = pre.value.conversation_id,
        .exit_code = pre.value.shellExitCode(),
    }).?;
    try std.testing.expectEqual(core.AgentCommandPhase.started, started.phase);
    try std.testing.expectEqualStrings("cursor", started.provider);
    try std.testing.expectEqualStrings("touch created.txt && echo made", started.command);
    try std.testing.expectEqualStrings("/work/proj", started.cwd);
    try std.testing.expect(started.exit_code == null);

    const post_source =
        \\{"conversation_id":"7f8ca51a-88f1-40a0-a73f-0f180d035134","tool_name":"Shell","tool_input":{"command":"touch created.txt && echo made"},
        \\"tool_output":"{\"output\":\"made\\n\",\"exitCode\":0}","duration":7412.529,"tool_use_id":"0b10deac-f115-4905-ab27-ed0fd5d14461",
        \\"cwd":"","hook_event_name":"postToolUse","workspace_roots":["/work/proj"]}
    ;
    const post = try std.json.parseFromSlice(CursorHookInput, std.testing.allocator, post_source, .{ .ignore_unknown_fields = true });
    defer post.deinit();
    const finished = mapToolCommand(.cursor, .{
        .event = post.value.toolEvent().?,
        .tool_name = post.value.tool_name,
        .tool_call_id = post.value.tool_use_id,
        .tool_input = post.value.tool_input,
        .cwd = post.value.shellDirectory(),
        .session = post.value.conversation_id,
        .exit_code = post.value.shellExitCode(),
    }).?;
    try std.testing.expectEqual(core.AgentCommandPhase.finished, finished.phase);
    try std.testing.expectEqual(@as(?i32, 0), finished.exit_code);
}

test "OpenCode plugin events map to reports and an interrupt settles the turn" {
    var buffer: hook_event.Buffer = undefined;
    const session = "ses_f212d4cc3ffeR3t3CA08EwN5Ap";

    const prompt = mapOpenCodeHook(.{ .event = "chat.message", .session_id = session, .busy = true }, &buffer).?;
    try std.testing.expectEqual(core.AgentReportState.working, prompt.state);
    try std.testing.expectEqualStrings(session, prompt.session);
    try std.testing.expectEqual(core.AgentReportState.working, mapOpenCodeHook(.{ .event = "session.status", .busy = true }, &buffer).?.state);
    try std.testing.expectEqual(core.AgentReportState.ready, mapOpenCodeHook(.{ .event = "session.status" }, &buffer).?.state);
    try std.testing.expectEqual(core.AgentReportState.working, mapOpenCodeHook(.{ .event = "state_snapshot", .busy = true }, &buffer).?.state);
    try std.testing.expectEqual(core.AgentReportState.working, mapOpenCodeHook(.{ .event = "permission.replied", .busy = true }, &buffer).?.state);
    try std.testing.expectEqual(core.AgentReportState.exited, mapOpenCodeHook(.{ .event = "dispose", .session_id = session }, &buffer).?.state);
    try std.testing.expectEqual(core.AgentReportState.ready, mapOpenCodeHook(.{ .event = "load" }, &buffer).?.state);

    // A second prompt still open keeps the pane blocked after the first reply.
    const still = mapOpenCodeHook(.{ .event = "question.replied", .busy = true, .blocked = .permission }, &buffer).?;
    try std.testing.expectEqual(core.AgentReportState.blocked, still.state);
    try std.testing.expectEqual(core.AgentBlockedReason.permission, still.blocked_reason);

    try std.testing.expect(mapOpenCodeHook(.{ .event = "tool.execute.after", .busy = true }, &buffer) == null);
    try std.testing.expect(mapOpenCodeHook(.{ .event = "session.updated", .title = "Fix proxy" }, &buffer) == null);
    try std.testing.expect(mapOpenCodeHook(.{ .event = "session.error" }, &buffer) == null);
    try std.testing.expectEqualStrings("", mapOpenCodeHook(.{ .event = "chat.message", .session_id = "../etc", .busy = true }, &buffer).?.session);
}

test "OpenCode permission and question prompts block with their request as the event line" {
    // `permission.asked` and `question.asked` as OpenCode 1.18.32 published
    // them, reshaped by the plugin into its payload.
    const permission_source =
        \\{"event":"permission.asked","session_id":"ses_f212d4cc3ffeR3t3CA08EwN5Ap","busy":true,"blocked":"permission",
        \\"tool_name":"bash","tool_input":{"command":"ls -la"}}
    ;
    const permission = try std.json.parseFromSlice(OpenCodeHookInput, std.testing.allocator, permission_source, .{ .ignore_unknown_fields = true });
    defer permission.deinit();
    var buffer: hook_event.Buffer = undefined;
    const asked = mapOpenCodeHook(permission.value, &buffer).?;
    try std.testing.expectEqual(core.AgentReportState.blocked, asked.state);
    try std.testing.expectEqual(core.AgentBlockedReason.permission, asked.blocked_reason);
    try std.testing.expectEqualStrings("» bash ls -la", asked.event);

    const question_source =
        \\{"event":"question.asked","session_id":"ses_f212d4cc3ffeR3t3CA08EwN5Ap","busy":true,"blocked":"question",
        \\"tool_input":{"questions":[{"question":"Which database?","header":"Database","options":[{"label":"SQLite","description":"Local"}]}]}}
    ;
    const question = try std.json.parseFromSlice(OpenCodeHookInput, std.testing.allocator, question_source, .{ .ignore_unknown_fields = true });
    defer question.deinit();
    const asking = mapOpenCodeHook(question.value, &buffer).?;
    try std.testing.expectEqual(core.AgentBlockedReason.question, asking.blocked_reason);
    try std.testing.expectEqualStrings("Which database?", asking.event);

    // OpenCode's edit, write and apply_patch ask as `edit` with the path in
    // `metadata.filepath` (packages/opencode/src/tool/edit.ts in v1.18.30).
    const edit_source =
        \\{"event":"permission.asked","session_id":"ses_f212d4cc3ffeR3t3CA08EwN5Ap","busy":true,"blocked":"permission",
        \\"tool_name":"edit","tool_input":{"filepath":"/work/proj/src/main.ts"}}
    ;
    const edit = try std.json.parseFromSlice(OpenCodeHookInput, std.testing.allocator, edit_source, .{ .ignore_unknown_fields = true });
    defer edit.deinit();
    try std.testing.expectEqualStrings("» edit /work/proj/src/main.ts", mapOpenCodeHook(edit.value, &buffer).?.event);

    // The renewal and a reply that leaves another prompt open carry that
    // prompt's request, so the event line keeps naming it.
    const renewal_source =
        \\{"event":"state_snapshot","session_id":"ses_f212d4cc3ffeR3t3CA08EwN5Ap","busy":true,"blocked":"permission",
        \\"tool_name":"bash","tool_input":{"command":"rm -rf build"}}
    ;
    const renewal = try std.json.parseFromSlice(OpenCodeHookInput, std.testing.allocator, renewal_source, .{ .ignore_unknown_fields = true });
    defer renewal.deinit();
    const renewed = mapOpenCodeHook(renewal.value, &buffer).?;
    try std.testing.expectEqual(core.AgentBlockedReason.permission, renewed.blocked_reason);
    try std.testing.expectEqualStrings("» bash rm -rf build", renewed.event);

    const reply_source =
        \\{"event":"permission.replied","session_id":"ses_f212d4cc3ffeR3t3CA08EwN5Ap","busy":true,"blocked":"question",
        \\"tool_input":{"questions":[{"question":"Which database?"}]}}
    ;
    const reply = try std.json.parseFromSlice(OpenCodeHookInput, std.testing.allocator, reply_source, .{ .ignore_unknown_fields = true });
    defer reply.deinit();
    try std.testing.expectEqualStrings("Which database?", mapOpenCodeHook(reply.value, &buffer).?.event);

    try std.testing.expectError(error.InvalidEnumTag, std.json.parseFromSlice(OpenCodeHookInput, std.testing.allocator, "{\"event\":\"state_snapshot\",\"blocked\":\"approval\"}", .{ .ignore_unknown_fields = true }));
}

test "OpenCode session titles report renames and clear OpenCode's default name" {
    var buffer: [core.max_agent_session_title_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("Fix proxy lifecycle", mapOpenCodeTitle(&buffer, .{ .event = "session.updated", .title = "Fix proxy lifecycle" }).?);
    try std.testing.expectEqualStrings("", mapOpenCodeTitle(&buffer, .{ .event = "session.updated", .title = "New session - 2026-09-26T17:45:45.532Z" }).?);
    try std.testing.expectEqualStrings("", mapOpenCodeTitle(&buffer, .{ .event = "session.updated", .title = "Child session - 2026-09-26T17:45:45.532Z" }).?);
    try std.testing.expectEqualStrings("New session - today", mapOpenCodeTitle(&buffer, .{ .event = "session.updated", .title = "New session - today" }).?);
    try std.testing.expectEqualStrings("New session - 2026-09-26T17:45:45.532", mapOpenCodeTitle(&buffer, .{ .event = "session.updated", .title = "New session - 2026-09-26T17:45:45.532" }).?);
    try std.testing.expect(mapOpenCodeTitle(&buffer, .{ .event = "session.updated" }) == null);
    try std.testing.expect(mapOpenCodeTitle(&buffer, .{ .event = "chat.message", .title = "Fix proxy" }) == null);

    const cut = mapOpenCodeTitle(&buffer, .{ .event = "session.updated", .title = "é" ** 60 }).?;
    try std.testing.expectEqual(@as(usize, 96), cut.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));
}

test "OpenCode bash calls open and close a command row with the exit status" {
    // `tool.execute.before` and `tool.execute.after` as OpenCode 1.18.32 ran
    // them for `echo hello-telar && false`, reshaped by the plugin.
    const before_source =
        \\{"event":"tool.execute.before","session_id":"ses_f212e24b9ffeeaehDu3OFjSrh8","tool_name":"bash",
        \\"tool_call_id":"call-b28da335-0761-4e54-9172-d71eac55aad4","tool_input":{"command":"echo hello-telar && false"},"cwd":"/work/proj"}
    ;
    const before = try std.json.parseFromSlice(OpenCodeHookInput, std.testing.allocator, before_source, .{ .ignore_unknown_fields = true });
    defer before.deinit();
    var buffer: hook_event.Buffer = undefined;
    const working = mapOpenCodeHook(before.value, &buffer).?;
    try std.testing.expectEqual(core.AgentReportState.working, working.state);
    try std.testing.expectEqualStrings("» bash echo hello-telar && false", working.event);

    const started = mapToolCommand(.opencode, .{
        .event = before.value.event,
        .tool_name = before.value.tool_name,
        .tool_call_id = before.value.tool_call_id,
        .tool_input = before.value.tool_input,
        .cwd = before.value.cwd,
        .session = before.value.session_id,
        .exit_code = before.value.exit_code,
    }).?;
    try std.testing.expectEqual(core.AgentCommandPhase.started, started.phase);
    try std.testing.expectEqualStrings("opencode", started.provider);
    try std.testing.expectEqualStrings("echo hello-telar && false", started.command);
    try std.testing.expectEqualStrings("/work/proj", started.cwd);
    try std.testing.expectEqualStrings("ses_f212e24b9ffeeaehDu3OFjSrh8", started.session);

    const after_source =
        \\{"event":"tool.execute.after","session_id":"ses_f212e24b9ffeeaehDu3OFjSrh8","tool_name":"bash",
        \\"tool_call_id":"call-b28da335-0761-4e54-9172-d71eac55aad4","tool_input":{"command":"echo hello-telar && false"},"cwd":"/work/proj","exit_code":1}
    ;
    const after = try std.json.parseFromSlice(OpenCodeHookInput, std.testing.allocator, after_source, .{ .ignore_unknown_fields = true });
    defer after.deinit();
    const finished = mapToolCommand(.opencode, .{
        .event = after.value.event,
        .tool_name = after.value.tool_name,
        .tool_call_id = after.value.tool_call_id,
        .tool_input = after.value.tool_input,
        .cwd = after.value.cwd,
        .session = after.value.session_id,
        .exit_code = after.value.exit_code,
    }).?;
    try std.testing.expectEqual(core.AgentCommandPhase.finished, finished.phase);
    try std.testing.expectEqual(@as(?i32, 1), finished.exit_code);

    const read = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"filePath\":\"/work/proj/README.md\"}", .{});
    defer read.deinit();
    try std.testing.expect(mapToolCommand(.opencode, .{
        .event = "tool.execute.before",
        .tool_name = "read",
        .tool_call_id = "call-1",
        .tool_input = read.value,
        .cwd = "/work/proj",
        .session = "ses_f212e24b9ffeeaehDu3OFjSrh8",
        .exit_code = null,
    }) == null);
    try std.testing.expectEqualStrings("» read /work/proj/README.md", mapOpenCodeHook(.{ .event = "tool.execute.before", .tool_name = "read", .tool_input = read.value }, &buffer).?.event);
}

test "An OpenCode tool call that starts under an open prompt keeps the prompt" {
    // OpenCode runs the calls of one step on their own, so a bash call can
    // start while another call's permission waits for the user.
    const source =
        \\{"event":"tool.execute.before","session_id":"ses_f212e24b9ffeeaehDu3OFjSrh8","blocked":"permission","tool_name":"bash",
        \\"tool_call_id":"call-2","tool_input":{"command":"git status"},"cwd":"/work/proj"}
    ;
    const parsed = try std.json.parseFromSlice(OpenCodeHookInput, std.testing.allocator, source, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var buffer: hook_event.Buffer = undefined;
    try std.testing.expect(mapOpenCodeHook(parsed.value, &buffer) == null);

    const started = mapToolCommand(.opencode, .{
        .event = parsed.value.event,
        .tool_name = parsed.value.tool_name,
        .tool_call_id = parsed.value.tool_call_id,
        .tool_input = parsed.value.tool_input,
        .cwd = parsed.value.cwd,
        .session = parsed.value.session_id,
        .exit_code = parsed.value.exit_code,
    }).?;
    try std.testing.expectEqualStrings("git status", started.command);
}
