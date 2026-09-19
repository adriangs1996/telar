const agent = @import("agent.zig");
const core = @import("telar-core");
const AgentHistoryInput = @import("../AgentHistoryInput.zig");
const values = @import("values.zig");
const AgentStatusType = @import("telar-core").AgentStatus;
const PaneTextSourceType = @import("telar-core").PaneTextSource;
const std = @import("std");
const max_agent_session_reference_bytes_module = @import("telar-core").max_agent_session_reference_bytes;
const max_pane_text_input_bytes_module = @import("telar-core").max_pane_text_input_bytes;
const Cursor = @import("Cursor.zig");
const AgentOptions = @This();

action: agent.AgentAction,
target: ?values.Target = null,
until: AgentStatusType = .done,
timeout_seconds: u32 = values.default_wait_timeout_seconds,
text: ?[*:0]const u8 = null,
wait_after_prompt: bool = false,
lines: u16 = 40,
source: PaneTextSourceType = .recent,
json: bool = false,
socket: ?[*:0]const u8 = null,
approval_id: ?u64 = null,
images: core.AgentImagePaths = .{},
model: ?[]const u8 = null,
effort: ?core.AgentEffort = null,
access: ?core.AgentAccess = null,
history: AgentHistoryInput = .{},

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
    else if (std.mem.eql(u8, action_text, "report-session"))
        .report_session
    else if (std.mem.eql(u8, action_text, "interrupt"))
        .interrupt
    else if (std.mem.eql(u8, action_text, "thread"))
        .thread
    else if (std.mem.eql(u8, action_text, "models"))
        .models
    else if (std.mem.eql(u8, action_text, "skills"))
        .skills
    else if (std.mem.eql(u8, action_text, "conversations"))
        .conversations
    else if (std.mem.eql(u8, action_text, "approvals"))
        .approvals
    else if (std.mem.eql(u8, action_text, "approve"))
        .approve
    else if (std.mem.eql(u8, action_text, "reject"))
        .reject
    else if (std.mem.eql(u8, action_text, "clear"))
        .clear
    else if (std.mem.eql(u8, action_text, "rename"))
        .rename
    else if (std.mem.eql(u8, action_text, "history"))
        .history
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

    if (action == .approve or action == .reject) {
        if (args.len < 3) {
            return error.MissingApprovalId;
        }

        const id = std.fmt.parseInt(u64, std.mem.span(args[2]), 10) catch return error.InvalidApprovalId;
        if (id == 0) {
            return error.InvalidApprovalId;
        }

        options.approval_id = id;
        index = 3;
    }

    if (action == .rename) {
        if (args.len < 3) {
            return error.MissingAgentTitle;
        }

        try core.validateSessionTitle(std.mem.span(args[2]));
        options.text = args[2];
        index = 3;
    }

    if (action == .report_session) {
        if (args.len < 3) {
            return error.MissingSessionReference;
        }

        options.text = args[2];
        if (std.mem.span(options.text.?).len == 0 or std.mem.span(options.text.?).len > max_agent_session_reference_bytes_module) {
            return error.InvalidSessionReference;
        }

        index = 3;
    }

    if (action == .prompt) {
        if (args.len < 3) {
            return error.MissingPromptText;
        }

        options.text = args[2];
        if (std.mem.span(options.text.?).len > max_pane_text_input_bytes_module) {
            return error.InvalidPromptText;
        }

        index = 3;
    }

    var cursor: Cursor = .{ .remaining = args[index..] };
    while (cursor.next()) |argument| {
        const arg = std.mem.span(argument);
        if (std.mem.eql(u8, arg, "--json")) {
            options.json = true;
        } else if (std.mem.eql(u8, arg, "--cursor") and action == .history) {
            const value = std.mem.span(try cursor.require(error.MissingHistoryCursor));
            _ = try core.AgentHistoryCursor.init(value);
            options.history.cursor = value;
        } else if (std.mem.eql(u8, arg, "--anchor") and action == .history) {
            options.history.anchor = std.mem.span(try cursor.require(error.MissingHistoryAnchor));
        } else if (std.mem.eql(u8, arg, "--anchor-turn") and action == .history) {
            options.history.anchor_turn = std.mem.span(try cursor.require(error.MissingHistoryAnchor));
        } else if (std.mem.eql(u8, arg, "--direction") and action == .history) {
            options.history.direction = std.meta.stringToEnum(core.agent_history.Direction, std.mem.span(try cursor.require(error.MissingHistoryDirection))) orelse return error.InvalidHistoryDirection;
        } else if (std.mem.eql(u8, arg, "--model")) {
            if (action != .prompt or options.model != null) {
                return error.InvalidModelOption;
            }

            const value = std.mem.span(try cursor.require(error.MissingModel));
            var selection: core.AgentOptions = .{};
            try selection.setModel(value);
            options.model = value;
        } else if (std.mem.eql(u8, arg, "--effort")) {
            if (action != .prompt or options.effort != null) {
                return error.InvalidEffortOption;
            }

            options.effort = try core.AgentEffort.init(std.mem.span(try cursor.require(error.MissingEffort)));
        } else if (std.mem.eql(u8, arg, "--access")) {
            if (action != .prompt or options.access != null) {
                return error.InvalidAccessOption;
            }

            options.access = std.meta.stringToEnum(core.AgentAccess, std.mem.span(try cursor.require(error.MissingAccess))) orelse return error.InvalidAccess;
        } else if (std.mem.eql(u8, arg, "--image")) {
            if (action != .prompt) {
                return error.UnknownAgentOption;
            }

            try options.images.append(std.mem.span(try cursor.require(error.MissingImagePath)));
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

            options.until = try values.parseWaitStatus(std.mem.span(value));
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

    if (action == .prompt and std.mem.span(options.text.?).len == 0 and options.images.count == 0) {
        return error.InvalidPromptText;
    }

    if (action == .history and ((options.history.anchor.len == 0) != (options.history.anchor_turn.len == 0) or (options.history.cursor.len != 0 and options.history.anchor.len != 0))) {
        return error.InvalidHistoryPosition;
    }

    return options;
}
