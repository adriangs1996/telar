const pane = @import("pane.zig");
const values = @import("values.zig");
const PaneTextSourceType = @import("telar-core").PaneTextSource;
const PaneDirectionType = @import("telar-core").PaneDirection;
const std = @import("std");
const max_pane_text_input_bytes_module = @import("telar-core").max_pane_text_input_bytes;
const Cursor = @import("Cursor.zig");
const PaneOptions = @This();

action: pane.PaneAction,
target: values.Target,
text: ?[*:0]const u8 = null,
enter: bool = false,
lines: u16 = 40,
source: PaneTextSourceType = .recent,
json: bool = false,
socket: ?[*:0]const u8 = null,
direction: ?PaneDirectionType = null,

pub fn parse(args: []const [*:0]const u8) !PaneOptions {
    if (args.len == 0) {
        return error.MissingPaneAction;
    }

    const action_text = std.mem.span(args[0]);
    const action: pane.PaneAction = if (std.mem.eql(u8, action_text, "read"))
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

    var options: PaneOptions = .{ .action = action, .target = values.Target.parse(args[1]) };
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
        if (std.mem.span(options.text.?).len == 0 or std.mem.span(options.text.?).len > max_pane_text_input_bytes_module) {
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

            options.lines = try values.parseLineCount(std.mem.span(value));
        } else if (std.mem.eql(u8, arg, "--source")) {
            if (action != .read) {
                return error.UnknownPaneOption;
            }
            const value = try cursor.require(error.MissingTextSource);

            options.source = try values.parseTextSource(std.mem.span(value));
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
            options.direction = pane.parsePaneDirection(std.mem.span(value)) orelse return error.InvalidPaneDirection;
        } else {
            return error.UnknownPaneOption;
        }
    }

    if (action == .focus and options.direction == null) {
        return error.MissingPaneDirection;
    }

    return options;
}
