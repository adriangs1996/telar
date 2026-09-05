//! Agent command grammar and validated options.

const std = @import("std");
const core = @import("telar-core");
const backend = @import("telar-backend");
const frontend = @import("telar-frontend");
const pty = backend.pty;
const Cursor = @import("cursor.zig").Cursor;
const values = @import("values.zig");
const Target = values.Target;
const max_wait_timeout_seconds = values.max_wait_timeout_seconds;
const default_wait_timeout_seconds = values.default_wait_timeout_seconds;
const HookAgent = values.HookAgent;
const parseHookAgent = values.parseHookAgent;
const parseWaitStatus = values.parseWaitStatus;
const parseTimeoutSeconds = values.parseTimeoutSeconds;
const parseLineCount = values.parseLineCount;
const parseTextSource = values.parseTextSource;

pub const AgentAction = enum { list, get, wait, prompt, read, report_session };

pub const AgentOptions = struct {
    action: AgentAction,
    target: ?Target = null,
    until: core.schema.AgentStatus = .done,
    timeout_seconds: u32 = default_wait_timeout_seconds,
    text: ?[*:0]const u8 = null,
    wait_after_prompt: bool = false,
    lines: u16 = 40,
    source: core.schema.PaneTextSource = .recent,
    json: bool = false,
    socket: ?[*:0]const u8 = null,

    pub fn parse(args: []const [*:0]const u8) !AgentOptions {
        if (args.len == 0) {
            return error.MissingAgentAction;
        }

        const action_text = std.mem.span(args[0]);
        const action: AgentAction = if (std.mem.eql(u8, action_text, "list"))
            .list
        else if (std.mem.eql(u8, action_text, "get"))
            .get
        else if (std.mem.eql(u8, action_text, "wait"))
            .wait
        else if (std.mem.eql(u8, action_text, "prompt"))
            .prompt
        else if (std.mem.eql(u8, action_text, "read"))
            .read
        else if (std.mem.eql(u8, action_text, "report-session"))
            .report_session
        else
            return error.UnknownAgentAction;
        var options: AgentOptions = .{ .action = action };
        var index: usize = 1;

        if (action != .list) {
            if (args.len < 2) {
                return error.MissingAgentTarget;
            }

            options.target = Target.parse(args[1]);
            index = 2;
        }

        if (action == .report_session) {
            if (args.len < 3) {
                return error.MissingSessionReference;
            }

            options.text = args[2];
            if (std.mem.span(options.text.?).len == 0 or std.mem.span(options.text.?).len > core.schema.max_agent_session_reference_bytes) {
                return error.InvalidSessionReference;
            }

            index = 3;
        }

        if (action == .prompt) {
            if (args.len < 3) {
                return error.MissingPromptText;
            }

            options.text = args[2];
            if (std.mem.span(options.text.?).len == 0 or std.mem.span(options.text.?).len > core.schema.max_pane_text_input_bytes) {
                return error.InvalidPromptText;
            }

            index = 3;
        }

        var cursor: Cursor = .{ .remaining = args[index..] };
        while (cursor.next()) |argument| {
            const arg = std.mem.span(argument);
            if (std.mem.eql(u8, arg, "--json")) {
                options.json = true;
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

                options.until = try parseWaitStatus(std.mem.span(value));
            } else if (std.mem.eql(u8, arg, "--timeout")) {
                if (action != .wait and action != .prompt) {
                    return error.UnknownAgentOption;
                }
                const value = try cursor.require(error.MissingTimeout);

                options.timeout_seconds = try parseTimeoutSeconds(std.mem.span(value));
            } else if (std.mem.eql(u8, arg, "--lines")) {
                if (action != .read) {
                    return error.UnknownAgentOption;
                }
                const value = try cursor.require(error.MissingLineCount);

                options.lines = try parseLineCount(std.mem.span(value));
            } else if (std.mem.eql(u8, arg, "--source")) {
                if (action != .read) {
                    return error.UnknownAgentOption;
                }
                const value = try cursor.require(error.MissingTextSource);

                options.source = try parseTextSource(std.mem.span(value));
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

        return options;
    }
};
