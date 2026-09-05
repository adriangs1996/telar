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
    /// Where the agent records its session, when the hook knows it.
    session_file: []const u8 = "",
    session_file_kind: schema.AgentSessionFileKind = .claude_transcript,
};

/// The subset of Claude Code hook input telar reads.
pub const ClaudeHookInput = struct {
    hook_event_name: []const u8 = "",
    session_id: []const u8 = "",
    agent_id: ?[]const u8 = null,
    transcript_path: []const u8 = "",
    /// Present on `SessionStart` when the session already has a name.
    session_title: []const u8 = "",
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
    /// Not part of Codex's payload: the state database `run` resolves from
    /// `CODEX_HOME`, where `/rename` lands as `threads.name`.
    state_database: []const u8 = "",
};

/// The payload the Telar extension for Pi sends. Pi has no hook files: the
/// extension installed by `telar integration install pi` runs
/// `telar hook pi` on Pi's own extension events.
pub const PiHookInput = struct {
    event: []const u8 = "",
    session_id: []const u8 = "",
    /// Whether Pi had no run in progress when the event fired.
    idle: ?bool = null,
    blocked: bool = false,
    tool_name: []const u8 = "",
    tool_call_id: []const u8 = "",
    tool_input: std.json.Value = .null,
    cwd: []const u8 = "",
    exit_code: ?i32 = null,
    /// The session name on `session_start` and `session_info_changed`.
    /// Absent on `session_info_changed` means the name was cleared.
    name: ?[]const u8 = null,
};

/// Everything one hook invocation may send: at most one lifecycle report,
/// one command report and one title report.
const Reports = struct {
    lifecycle: ?Report = null,
    command: ?CommandReport = null,
    /// Empty clears an earlier agent title.
    title: ?[]const u8 = null,
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

    if (std.mem.eql(u8, event, "session_start") or
        std.mem.eql(u8, event, "agent_settled") or
        std.mem.eql(u8, event, "ui_prompt_end") or
        std.mem.eql(u8, event, "state_snapshot"))
    {
        const idle = input.idle orelse (std.mem.eql(u8, event, "session_start") or std.mem.eql(u8, event, "agent_settled"));
        return .{ .state = if (input.blocked) .blocked else if (idle) .ready else .working, .session = session };
    }

    if (std.mem.eql(u8, event, "agent_start")) {
        return .{ .state = .working, .session = session };
    }

    if (std.mem.eql(u8, event, "ui_prompt_start")) {
        return .{ .state = .blocked, .session = session };
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
pub fn mapPiTitle(buffer: *[schema.max_agent_session_title_bytes]u8, input: PiHookInput) ?[]const u8 {
    const name = if (std.mem.eql(u8, input.event, "session_info_changed"))
        input.name orelse ""
    else if (std.mem.eql(u8, input.event, "session_start"))
        input.name orelse return null
    else
        return null;

    return schema.truncateSessionTitle(buffer, name);
}

/// Maps one Claude Code hook event to a report. Subagent events and
/// notifications that do not change what the user must do are ignored.
///
/// ```zig
/// const report = mapClaudeHook(input) orelse return;
/// ```
pub fn mapClaudeHook(input: ClaudeHookInput) ?Report {
    const session_file = if (input.transcript_path.len <= schema.max_agent_session_file_bytes) input.transcript_path else "";
    if (input.agent_id != null and input.agent_id.?.len != 0) {
        return null;
    }

    const event = input.hook_event_name;
    const session = if (schema.validateSessionReference(input.session_id)) |_| input.session_id else |_| "";

    if (std.mem.eql(u8, event, "SessionStart")) {
        return .{ .state = .ready, .session = session, .session_file = session_file };
    }
    if (std.mem.eql(u8, event, "UserPromptSubmit")) {
        return .{ .state = .working, .session = session, .session_file = session_file };
    }
    if (std.mem.eql(u8, event, "PreToolUse") or std.mem.eql(u8, event, "PostToolUse")) {
        return .{ .state = .working, .session = session, .session_file = session_file };
    }
    if (std.mem.eql(u8, event, "Stop")) {
        return .{ .state = .ready, .session = session, .session_file = session_file };
    }
    if (std.mem.eql(u8, event, "SessionEnd")) {
        return .{ .state = .exited, .session_file = session_file };
    }
    if (std.mem.eql(u8, event, "Notification")) {
        for ([_][]const u8{ "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input" }) |blocked| {
            if (std.mem.eql(u8, input.notification_type, blocked)) {
                return .{ .state = .blocked, .session = session, .session_file = session_file };
            }
        }
        if (std.mem.eql(u8, input.notification_type, "idle_prompt")) {
            return .{ .state = .ready, .session = session, .session_file = session_file };
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
pub fn mapClaudeTitle(buffer: *[schema.max_agent_session_title_bytes]u8, input: ClaudeHookInput) ?[]const u8 {
    if (!std.mem.eql(u8, input.hook_event_name, "SessionStart") or input.session_title.len == 0 or input.agent_id != null) {
        return null;
    }

    return schema.truncateSessionTitle(buffer, input.session_title);
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
pub fn codexStateDatabase(io: Io, home: []const u8, buffer: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    var directory = Io.Dir.cwd().openDir(io, home, .{ .iterate = true }) catch return null;
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

/// Maps one Codex hook event to a report. Subagent events are ignored. A
/// compacted session remains working; `Stop` starts settlement, which still
/// needs a newer idle composer before it can announce completion.
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
    const file = if (input.state_database.len <= schema.max_agent_session_file_bytes) input.state_database else "";

    if (std.mem.eql(u8, event, "SessionStart")) {
        const state: schema.AgentReportState = if (std.mem.eql(u8, input.source, "compact")) .working else .ready;
        return .{ .state = state, .session = session, .session_file = file, .session_file_kind = .codex_state };
    }
    if (std.mem.eql(u8, event, "UserPromptSubmit") or std.mem.eql(u8, event, "PreToolUse") or std.mem.eql(u8, event, "PostToolUse")) {
        return .{ .state = .working, .session = session, .session_file = file, .session_file_kind = .codex_state };
    }
    if (std.mem.eql(u8, event, "PermissionRequest")) {
        return .{ .state = .blocked, .session = session, .session_file = file, .session_file_kind = .codex_state };
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
    const target: Target = .{
        .socket = options.socket,
        .pane = .{ .pane_id = pane_id, .pane_generation = pane_generation },
    };
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
            var title_buffer: [schema.max_agent_session_title_bytes]u8 = undefined;
            sendReports(init, target, .{
                .lifecycle = mapClaudeHook(parsed.value),
                .command = command,
                .title = mapClaudeTitle(&title_buffer, parsed.value),
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
            sendReports(init, target, .{ .lifecycle = mapCodexHook(parsed.value), .command = command });
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
            var title_buffer: [schema.max_agent_session_title_bytes]u8 = undefined;
            sendReports(init, target, .{
                .lifecycle = mapPiHook(parsed.value),
                .command = command,
                .title = mapPiTitle(&title_buffer, parsed.value),
            });
        },
    }
}

/// The runtime socket and the pane generation a hook reports for.
const Target = struct {
    socket: ?[*:0]const u8,
    pane: control.Session.PaneRef,
};

fn sendReports(init: std.process.Init, target: Target, reports: Reports) void {
    if (reports.lifecycle == null and reports.command == null and reports.title == null) {
        return;
    }

    // Attach only. The pane environment survives a stopped runtime, and a
    // hook that started one would resurrect it from every orphaned agent.
    var session = control.Session.attach(init, target.socket) catch return;
    defer session.close();
    const pane = target.pane;
    if (reports.lifecycle) |lifecycle| {
        session.reportAgent(pane, .{
            .state = lifecycle.state,
            .session = lifecycle.session,
            .session_file = lifecycle.session_file,
            .session_file_kind = lifecycle.session_file_kind,
        }) catch return;
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

test "Pi session names map to title reports and a cleared name to an empty title" {
    var buffer: [schema.max_agent_session_title_bytes]u8 = undefined;
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
    try std.testing.expectEqual(schema.AgentReportState.ready, report.state);
    try std.testing.expectEqualStrings("01a061a3-a2e7-7574-9e07-997b8d59340d", report.session);
    try std.testing.expectError(error.SyntaxError, std.json.parseFromSlice(PiHookInput, std.testing.allocator, "not json", .{ .ignore_unknown_fields = true }));
}

test "Claude session titles and transcripts ride along with the hook reports" {
    var buffer: [schema.max_agent_session_title_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("Fix proxy", mapClaudeTitle(&buffer, .{ .hook_event_name = "SessionStart", .session_title = "Fix proxy" }).?);
    try std.testing.expect(mapClaudeTitle(&buffer, .{ .hook_event_name = "SessionStart" }) == null);
    try std.testing.expect(mapClaudeTitle(&buffer, .{ .hook_event_name = "Stop", .session_title = "Fix proxy" }) == null);
    try std.testing.expect(mapClaudeTitle(&buffer, .{ .hook_event_name = "SessionStart", .session_title = "Fix proxy", .agent_id = "sub-1" }) == null);

    const report = mapClaudeHook(.{ .hook_event_name = "Stop", .transcript_path = "/home/me/.claude/projects/p/s.jsonl" }).?;
    try std.testing.expectEqualStrings("/home/me/.claude/projects/p/s.jsonl", report.session_file);
    try std.testing.expectEqual(schema.AgentSessionFileKind.claude_transcript, report.session_file_kind);
    const long = "/" ** (schema.max_agent_session_file_bytes + 1);
    try std.testing.expectEqualStrings("", mapClaudeHook(.{ .hook_event_name = "Stop", .transcript_path = long }).?.session_file);
    try std.testing.expectEqualStrings("", mapCodexHook(.{ .hook_event_name = "Stop" }).?.session_file);
}

test "Codex reports carry the resolved state database and find the newest schema" {
    const report = mapCodexHook(.{ .hook_event_name = "Stop", .state_database = "/home/me/.codex/state_5.sqlite" }).?;
    try std.testing.expectEqualStrings("/home/me/.codex/state_5.sqlite", report.session_file);
    try std.testing.expectEqual(schema.AgentSessionFileKind.codex_state, report.session_file_kind);
    try std.testing.expectEqual(schema.AgentSessionFileKind.codex_state, mapCodexHook(.{ .hook_event_name = "SessionEnd", .state_database = "/x" }).?.session_file_kind);

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
    try std.testing.expectEqual(schema.AgentReportState.settling, mapCodexHook(.{ .hook_event_name = "Stop" }).?.state);
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

test "Pi snapshots preserve active runs and nested prompts" {
    try std.testing.expectEqual(schema.AgentReportState.working, mapPiHook(.{ .event = "state_snapshot", .idle = false }).?.state);
    try std.testing.expectEqual(schema.AgentReportState.ready, mapPiHook(.{ .event = "state_snapshot", .idle = true }).?.state);
    try std.testing.expectEqual(schema.AgentReportState.blocked, mapPiHook(.{ .event = "ui_prompt_end", .idle = true, .blocked = true }).?.state);
    try std.testing.expectEqual(schema.AgentReportState.working, mapPiHook(.{ .event = "agent_settled", .idle = false }).?.state);
    try std.testing.expectEqual(schema.AgentReportState.working, mapPiHook(.{ .event = "session_start", .idle = false }).?.state);
}
