//! Pane command grammar and validated options.

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

pub const PaneAction = enum { read, send_keys, focus };

pub const PaneOptions = struct {
    action: PaneAction,
    target: Target,
    text: ?[*:0]const u8 = null,
    enter: bool = false,
    lines: u16 = 40,
    source: core.schema.PaneTextSource = .recent,
    json: bool = false,
    socket: ?[*:0]const u8 = null,
    direction: ?core.schema.PaneDirection = null,

    pub fn parse(args: []const [*:0]const u8) !PaneOptions {
        if (args.len == 0) {
            return error.MissingPaneAction;
        }

        const action_text = std.mem.span(args[0]);
        const action: PaneAction = if (std.mem.eql(u8, action_text, "read"))
            .read
        else if (std.mem.eql(u8, action_text, "send-keys"))
            .send_keys
        else if (std.mem.eql(u8, action_text, "focus"))
            .focus
        else
            return error.UnknownPaneAction;
        if (args.len < 2) {
            return error.MissingPaneTarget;
        }

        var options: PaneOptions = .{ .action = action, .target = Target.parse(args[1]) };
        if (options.target == .name) {
            return error.InvalidPaneId;
        }
        if (action == .focus and options.target != .current) {
            return error.FocusRequiresCurrentPane;
        }

        var index: usize = 2;
        if (action == .send_keys) {
            if (args.len < 3) {
                return error.MissingSendText;
            }

            options.text = args[2];
            if (std.mem.span(options.text.?).len == 0 or std.mem.span(options.text.?).len > core.schema.max_pane_text_input_bytes) {
                return error.InvalidSendText;
            }

            index = 3;
        }

        var cursor: Cursor = .{ .remaining = args[index..] };
        while (cursor.next()) |argument| {
            const arg = std.mem.span(argument);
            if (std.mem.eql(u8, arg, "--json")) {
                options.json = true;
            } else if (std.mem.eql(u8, arg, "--enter")) {
                if (action != .send_keys) {
                    return error.UnknownPaneOption;
                }

                options.enter = true;
            } else if (std.mem.eql(u8, arg, "--lines")) {
                if (action != .read) {
                    return error.UnknownPaneOption;
                }
                const value = try cursor.require(error.MissingLineCount);

                options.lines = try parseLineCount(std.mem.span(value));
            } else if (std.mem.eql(u8, arg, "--source")) {
                if (action != .read) {
                    return error.UnknownPaneOption;
                }
                const value = try cursor.require(error.MissingTextSource);

                options.source = try parseTextSource(std.mem.span(value));
            } else if (std.mem.eql(u8, arg, "--socket")) {
                const value = try cursor.require(error.MissingSocketPath);
                if (options.socket != null) {
                    return error.DuplicateSocketOption;
                }

                options.socket = value;
            } else if (std.mem.eql(u8, arg, "--direction")) {
                if (action != .focus or cursor.remaining.len == 0 or options.direction != null) {
                    return error.UnknownPaneOption;
                }

                const value = try cursor.require(error.UnknownPaneOption);
                options.direction = parsePaneDirection(std.mem.span(value)) orelse return error.InvalidPaneDirection;
            } else {
                return error.UnknownPaneOption;
            }
        }

        if (action == .focus and options.direction == null) {
            return error.MissingPaneDirection;
        }

        return options;
    }
};

fn parsePaneDirection(value: []const u8) ?core.schema.PaneDirection {
    if (std.mem.eql(u8, value, "left")) {
        return .left;
    }

    if (std.mem.eql(u8, value, "right")) {
        return .right;
    }

    if (std.mem.eql(u8, value, "up")) {
        return .up;
    }

    if (std.mem.eql(u8, value, "down")) {
        return .down;
    }

    return null;
}
