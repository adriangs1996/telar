const max_search_needle_bytes = @import("telar-core").max_search_needle_bytes;
const pane = @import("pane.zig");
const entity_target = @import("entity_target.zig");
const values = @import("values.zig");
const PaneTextSourceType = @import("telar-core").PaneTextSource;
const PaneDirectionType = @import("telar-core").PaneDirection;
const std = @import("std");
const max_pane_text_input_bytes_module = @import("telar-core").max_pane_text_input_bytes;
const Cursor = @import("Cursor.zig");
const PaneOptions = @This();

action: pane.PaneAction,
target: values.Target = .current,
workspace: ?entity_target.Target = null,
tab: ?entity_target.Target = null,
text: ?[*:0]const u8 = null,
enter: bool = false,
lines: u16 = 40,
source: PaneTextSourceType = .recent,
json: bool = false,
socket: ?[*:0]const u8 = null,
direction: ?PaneDirectionType = null,
count: ?u32 = null,
interval_ms: u32 = 250,

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
    else if (std.mem.eql(u8, action_text, "watch"))
        .watch
    else if (std.mem.eql(u8, action_text, "search"))
        .search
    else if (std.mem.eql(u8, action_text, "list"))
        .list
    else if (std.mem.eql(u8, action_text, "get"))
        .get
    else
        return error.UnknownPaneAction;
    if (action != .list and args.len < 2) {
        return error.MissingPaneTarget;
    }

    var options: PaneOptions = .{ .action = action };
    if (action != .list) {
        options.target = values.Target.parse(args[1]);
    }
    if (options.target == .name) {
        return error.InvalidPaneId;
    }
    if (action == .focus and options.target != .current) {
        return error.FocusRequiresCurrentPane;
    }

    var index: usize = if (action == .list) 1 else 2;
    if (action == .search) {
        if (args.len < 3) {
            return error.MissingSearchText;
        }

        options.text = args[2];
        const text = std.mem.span(options.text.?);
        if (text.len == 0 or text.len > max_search_needle_bytes or !std.unicode.utf8ValidateSlice(text)) {
            return error.InvalidSearchText;
        }

        index = 3;
    }

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
        if (std.mem.eql(u8, arg, "--json") or (action == .watch and std.mem.eql(u8, arg, "--jsonl"))) {
            options.json = true;
        } else if (std.mem.eql(u8, arg, "--workspace") and (action == .list or action == .get or action == .watch)) {
            if (options.workspace != null) {
                return error.DuplicateWorkspaceOption;
            }

            options.workspace = try entity_target.Target.parse(std.mem.span(try cursor.require(error.MissingWorkspaceId)));
        } else if (std.mem.eql(u8, arg, "--tab") and (action == .list or action == .get or action == .watch)) {
            if (options.tab != null) {
                return error.DuplicateTabOption;
            }

            options.tab = try entity_target.Target.parse(std.mem.span(try cursor.require(error.MissingTabId)));
        } else if (std.mem.eql(u8, arg, "--enter")) {
            if (action != .send_keys) {
                return error.UnknownPaneOption;
            }

            options.enter = true;
        } else if (std.mem.eql(u8, arg, "--lines")) {
            if (action != .read and action != .watch) {
                return error.UnknownPaneOption;
            }
            const value = try cursor.require(error.MissingLineCount);

            options.lines = try values.parseLineCount(std.mem.span(value));
        } else if (std.mem.eql(u8, arg, "--source")) {
            if (action != .read and action != .watch) {
                return error.UnknownPaneOption;
            }
            const value = try cursor.require(error.MissingTextSource);

            options.source = try values.parseTextSource(std.mem.span(value));
        } else if (std.mem.eql(u8, arg, "--count") and action == .watch and options.count == null) {
            options.count = std.fmt.parseUnsigned(u32, std.mem.span(try cursor.require(error.MissingCount)), 10) catch return error.InvalidCount;
            if (options.count == 0) {
                return error.InvalidCount;
            }
        } else if (std.mem.eql(u8, arg, "--interval-ms") and action == .watch) {
            options.interval_ms = std.fmt.parseUnsigned(u32, std.mem.span(try cursor.require(error.MissingInterval)), 10) catch return error.InvalidInterval;
            if (options.interval_ms < 10 or options.interval_ms > 60000) {
                return error.InvalidInterval;
            }
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

    if (options.tab != null and options.workspace == null) {
        return error.TabRequiresWorkspace;
    }

    return options;
}
