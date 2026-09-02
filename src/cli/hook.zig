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
};

/// The subset of Codex hook input telar reads.
pub const CodexHookInput = struct {
    hook_event_name: []const u8 = "",
    session_id: []const u8 = "",
    agent_id: ?[]const u8 = null,
    source: []const u8 = "",
};

/// The payload the Telar extension for Pi sends. Pi has no hook files: the
/// extension installed by `telar integration install pi` runs
/// `telar hook pi` on Pi's own extension events.
pub const PiHookInput = struct {
    event: []const u8 = "",
    session_id: []const u8 = "",
    /// Whether Pi had no run in progress when the event fired.
    idle: ?bool = null,
};

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
    if (std.mem.eql(u8, event, "UserPromptSubmit") or std.mem.eql(u8, event, "PostToolUse")) {
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
    const report = switch (options.agent) {
        .claude => parseClaude(init.gpa, input[0..len]) orelse return,
        .codex => parseCodex(init.gpa, input[0..len]) orelse return,
        .pi => parsePi(init.gpa, input[0..len]) orelse return,
    };

    var session = control.Session.open(init, options.socket) catch return;
    defer session.close();
    session.reportAgent(.{ .pane_id = pane_id, .pane_generation = pane_generation }, report.state, report.session) catch return;
}

fn parseClaude(gpa: std.mem.Allocator, bytes: []const u8) ?Report {
    const parsed = std.json.parseFromSlice(ClaudeHookInput, gpa, bytes, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const mapped = mapClaudeHook(parsed.value) orelse return null;
    return .{ .state = mapped.state, .session = mapped.session };
}

fn parseCodex(gpa: std.mem.Allocator, bytes: []const u8) ?Report {
    const parsed = std.json.parseFromSlice(CodexHookInput, gpa, bytes, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const mapped = mapCodexHook(parsed.value) orelse return null;
    return .{ .state = mapped.state, .session = mapped.session };
}

fn parsePi(gpa: std.mem.Allocator, bytes: []const u8) ?Report {
    const parsed = std.json.parseFromSlice(PiHookInput, gpa, bytes, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const mapped = mapPiHook(parsed.value) orelse return null;
    return .{ .state = mapped.state, .session = mapped.session };
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
    const report = parsePi(std.testing.allocator, "{\"event\":\"session_start\",\"session_id\":\"01a061a3-a2e7-7574-9e07-997b8d59340d\",\"idle\":true}").?;
    try std.testing.expectEqual(schema.AgentReportState.ready, report.state);
    try std.testing.expectEqualStrings("01a061a3-a2e7-7574-9e07-997b8d59340d", report.session);
    try std.testing.expect(parsePi(std.testing.allocator, "not json") == null);
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
    try std.testing.expect(mapClaudeHook(.{ .hook_event_name = "PreToolUse" }) == null);
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
    try std.testing.expect(mapCodexHook(.{ .hook_event_name = "PreToolUse" }) == null);
    try std.testing.expect(mapCodexHook(.{ .hook_event_name = "PostToolUse", .agent_id = "sub-1" }) == null);
    try std.testing.expectEqualStrings("", mapCodexHook(.{ .hook_event_name = "Stop", .session_id = "bad session" }).?.session);
}

test "Codex hook JSON accepts the official event payload" {
    const session = "0192aaaa-bbbb-cccc-dddd-eeeeffff0000";
    const payload =
        \\{"session_id":"0192aaaa-bbbb-cccc-dddd-eeeeffff0000","turn_id":"turn-1","transcript_path":null,"cwd":"/work","hook_event_name":"PermissionRequest","model":"gpt-5.6-sol","permission_mode":"default","tool_name":"exec_command","tool_input":{"cmd":"zig build test"}}
    ;
    const report = parseCodex(std.testing.allocator, payload).?;

    try std.testing.expectEqual(schema.AgentReportState.blocked, report.state);
    try std.testing.expectEqualStrings(session, report.session);
}
