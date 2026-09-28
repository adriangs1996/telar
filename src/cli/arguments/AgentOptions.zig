const agent = @import("agent.zig");
const core = @import("telar-core");
const AgentReport = @import("../AgentReport.zig");
const AgentCommandReport = @import("../AgentCommandReport.zig");
const values = @import("values.zig");
const std = @import("std");
const Cursor = @import("Cursor.zig");
const AgentOptions = @This();

action: agent.AgentAction,
target: ?values.Target = null,
until: values.WaitCondition = .{ .status = .done },
/// `prompt --interrupt`: stop the current turn before sending.
interrupt_first: bool = false,
timeout_seconds: u32 = values.default_wait_timeout_seconds,
text: ?[*:0]const u8 = null,
wait_after_prompt: bool = false,
lines: u16 = 40,
source: core.PaneTextSource = .recent,
json: bool = false,
socket: ?[*:0]const u8 = null,
report: ?AgentReport = null,
command_report: ?AgentCommandReport = null,

pub fn parse(args: []const [*:0]const u8) !AgentOptions {
    if (args.len == 0) {
        return error.MissingAgentAction;
    }

    const action_text = std.mem.span(args[0]);
    const action: agent.AgentAction = if (std.mem.eql(u8, action_text, "list"))
        .list
    else if (std.mem.eql(u8, action_text, "get"))
        .get
    else if (std.mem.eql(u8, action_text, "wait"))
        .wait
    else if (std.mem.eql(u8, action_text, "prompt"))
        .prompt
    else if (std.mem.eql(u8, action_text, "read"))
        .read
    else if (std.mem.eql(u8, action_text, "interrupt"))
        .interrupt
    else if (std.mem.eql(u8, action_text, "report-session"))
        .report_session
    else if (std.mem.eql(u8, action_text, "report-title"))
        .report_title
    else if (std.mem.eql(u8, action_text, "report-state"))
        .report_state
    else if (std.mem.eql(u8, action_text, "report-command"))
        .report_command
    else if (std.mem.eql(u8, action_text, "acknowledge"))
        .acknowledge
    else
        return error.UnknownAgentAction;
    var options: AgentOptions = .{ .action = action };
    var index: usize = 1;

    if (action != .list) {
        if (args.len < 2) {
            return error.MissingAgentTarget;
        }

        options.target = values.Target.parse(args[1]);
        index = 2;
    }

    if (action == .report_command) {
        if (args.len < 4) {
            return error.MissingCommandReport;
        }

        options.command_report = .{
            .phase = std.meta.stringToEnum(core.AgentCommandPhase, std.mem.span(args[2])) orelse return error.InvalidCommandPhase,
            .command = std.mem.span(args[3]),
            .provider = "",
            .tool_call_id = "",
            .cwd = "",
            .session = "",
            .exit_code = null,
        };
        index = 4;
    }

    if (action == .report_state) {
        if (args.len < 3) {
            return error.MissingAgentState;
        }

        options.report = .{ .state = std.meta.stringToEnum(core.AgentReportState, std.mem.span(args[2])) orelse return error.InvalidAgentState };
        index = 3;
    }

    if (action == .report_title) {
        if (args.len < 3) {
            return error.MissingAgentTitle;
        }

        if (std.mem.span(args[2]).len != 0) {
            try core.validateSessionTitle(std.mem.span(args[2]));
        }

        options.text = args[2];
        index = 3;
    }

    if (action == .report_session) {
        if (args.len < 3) {
            return error.MissingSessionReference;
        }

        options.text = args[2];
        if (std.mem.span(options.text.?).len == 0 or std.mem.span(options.text.?).len > core.max_agent_session_reference_bytes) {
            return error.InvalidSessionReference;
        }

        index = 3;
    }

    if (action == .prompt) {
        if (args.len < 3) {
            return error.MissingPromptText;
        }

        options.text = args[2];
        if (std.mem.span(options.text.?).len > core.max_pane_text_input_bytes) {
            return error.InvalidPromptText;
        }

        index = 3;
    }

    var cursor: Cursor = .{ .remaining = args[index..] };
    while (cursor.next()) |argument| {
        const arg = std.mem.span(argument);
        if (std.mem.eql(u8, arg, "--json")) {
            options.json = true;
        } else if (std.mem.eql(u8, arg, "--provider") and action == .report_command) {
            options.command_report.?.provider = std.mem.span(try cursor.require(error.MissingProvider));
        } else if (std.mem.eql(u8, arg, "--tool-call") and action == .report_command) {
            options.command_report.?.tool_call_id = std.mem.span(try cursor.require(error.MissingToolCall));
        } else if (std.mem.eql(u8, arg, "--cwd") and action == .report_command) {
            options.command_report.?.cwd = std.mem.span(try cursor.require(error.MissingCwd));
        } else if (std.mem.eql(u8, arg, "--session") and action == .report_command) {
            options.command_report.?.session = std.mem.span(try cursor.require(error.MissingSessionReference));
        } else if (std.mem.eql(u8, arg, "--exit-code") and action == .report_command) {
            options.command_report.?.exit_code = std.fmt.parseInt(i32, std.mem.span(try cursor.require(error.MissingExitCode)), 10) catch return error.InvalidExitCode;
        } else if (std.mem.eql(u8, arg, "--blocked-reason") and action == .report_state) {
            options.report.?.blocked_reason = std.meta.stringToEnum(core.AgentBlockedReason, std.mem.span(try cursor.require(error.MissingBlockedReason))) orelse return error.InvalidBlockedReason;
        } else if (std.mem.eql(u8, arg, "--event") and action == .report_state) {
            options.report.?.event = std.mem.span(try cursor.require(error.MissingAgentEvent));
        } else if (std.mem.eql(u8, arg, "--session") and action == .report_state) {
            options.report.?.session = std.mem.span(try cursor.require(error.MissingSessionReference));
        } else if (std.mem.eql(u8, arg, "--session-file") and action == .report_state) {
            options.report.?.session_file = std.mem.span(try cursor.require(error.MissingSessionFile));
        } else if (std.mem.eql(u8, arg, "--session-file-kind") and action == .report_state) {
            options.report.?.session_file_kind = std.meta.stringToEnum(core.AgentSessionFileKind, std.mem.span(try cursor.require(error.MissingSessionFileKind))) orelse return error.InvalidSessionFileKind;
        } else if (std.mem.eql(u8, arg, "--interrupt")) {
            if (action != .prompt) {
                return error.UnknownAgentOption;
            }

            options.interrupt_first = true;
        } else if (std.mem.eql(u8, arg, "--wait")) {
            if (action != .prompt) {
                return error.UnknownAgentOption;
            }

            options.wait_after_prompt = true;
        } else if (std.mem.eql(u8, arg, "--until")) {
            if (action != .wait) {
                return error.UnknownAgentOption;
            }
            const value = try cursor.require(error.MissingWaitStatus);

            options.until = try values.parseWaitCondition(std.mem.span(value));
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            if (action != .wait and action != .prompt) {
                return error.UnknownAgentOption;
            }
            const value = try cursor.require(error.MissingTimeout);

            options.timeout_seconds = try values.parseTimeoutSeconds(std.mem.span(value));
        } else if (std.mem.eql(u8, arg, "--lines")) {
            if (action != .read) {
                return error.UnknownAgentOption;
            }
            const value = try cursor.require(error.MissingLineCount);

            options.lines = try values.parseLineCount(std.mem.span(value));
        } else if (std.mem.eql(u8, arg, "--source")) {
            if (action != .read) {
                return error.UnknownAgentOption;
            }
            const value = try cursor.require(error.MissingTextSource);

            options.source = try values.parseTextSource(std.mem.span(value));
        } else if (std.mem.eql(u8, arg, "--socket")) {
            const value = try cursor.require(error.MissingSocketPath);
            if (options.socket != null) {
                return error.DuplicateSocketOption;
            }

            options.socket = value;
        } else {
            return error.UnknownAgentOption;
        }
    }

    if (action == .prompt and std.mem.span(options.text.?).len == 0) {
        return error.InvalidPromptText;
    }

    if (options.command_report) |report| {
        if (report.provider.len == 0 or report.command.len == 0 or (report.phase == .started and report.exit_code != null)) {
            return error.InvalidCommandReport;
        }
    }

    return options;
}
