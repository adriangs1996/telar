const std = @import("std");
const core = @import("telar-core");
const Cursor = @import("Cursor.zig");
const RoutedOptions = @This();

action: core.ClientAction,
client_id: u64 = 0,
target_id: u64 = 0,
value: i64 = 0,
text: []const u8 = "",
json: bool = false,
socket: ?[*:0]const u8 = null,

/// Recognizes actions owned by a specific UI. Example: `if (try RoutedOptions.parse(args)) |options| { ... }`
pub fn parse(args: []const [*:0]const u8) !?RoutedOptions {
    if (args.len < 2) {
        return null;
    }

    const group = std.mem.span(args[0]);
    const verb = std.mem.span(args[1]);
    var name_buffer: [64]u8 = undefined;
    const nested = (std.mem.eql(u8, group, "client") and (std.mem.eql(u8, verb, "open") or std.mem.eql(u8, verb, "clipboard"))) or
        (std.mem.eql(u8, group, "agent") and (std.mem.eql(u8, verb, "draft") or std.mem.eql(u8, verb, "view")));
    const consumed: usize = if (nested) 3 else 2;
    if (args.len < consumed) {
        return error.MissingClientAction;
    }

    const name = if (nested)
        std.fmt.bufPrint(&name_buffer, "{s}_{s}_{s}", .{ group, verb, std.mem.span(args[2]) }) catch return null
    else
        std.fmt.bufPrint(&name_buffer, "{s}_{s}", .{ group, verb }) catch return null;
    for (name) |*byte| {
        if (byte.* == '-') {
            byte.* = '_';
        }
    }

    const action = std.meta.stringToEnum(core.ClientAction, name) orelse return null;
    if (action == .pane_focus) {
        for (args[2..]) |argument| {
            const arg = std.mem.span(argument);
            if (std.mem.eql(u8, arg, "--current") or std.mem.eql(u8, arg, "--direction")) {
                return null;
            }
        }
    }

    var self: RoutedOptions = .{ .action = action };
    var cursor: Cursor = .{ .remaining = args[consumed..] };
    switch (action) {
        .plugin_enable => self.text = std.mem.span(try cursor.require(error.MissingPlugin)),
        .plugin_get => self.text = std.mem.span(try cursor.require(error.MissingPlugin)),
        .plugin_list => {},
        .config_show => {},
        .config_reload => {},
        .layout_apply => self.text = std.mem.span(try cursor.require(error.MissingLayoutToken)),
        .layout_get => {},
        .pane_copy => {
            self.target_id = try positive(std.mem.span(try cursor.require(error.MissingTarget)));
            self.text = std.mem.span(try cursor.require(error.MissingCopyRange));
            _ = try core.CopySelection.fromText(@enumFromInt(self.target_id), self.text);
        },
        .agent_view_collapse => {
            self.target_id = try positive(std.mem.span(try cursor.require(error.MissingTarget)));
            self.text = std.mem.span(try cursor.require(error.MissingItemId));
            _ = try positive(self.text);
        },
        .agent_view_expand => {
            self.target_id = try positive(std.mem.span(try cursor.require(error.MissingTarget)));
            self.text = std.mem.span(try cursor.require(error.MissingItemId));
            _ = try positive(self.text);
        },
        .agent_draft_attach => {
            self.target_id = try positive(std.mem.span(try cursor.require(error.MissingTarget)));
            self.text = std.mem.span(try cursor.require(error.MissingText));
            if (!std.fs.path.isAbsolute(self.text)) {
                return error.ImagePathMustBeAbsolute;
            }
        },
        .agent_draft_set => {
            self.target_id = try positive(std.mem.span(try cursor.require(error.MissingTarget)));
            self.text = std.mem.span(try cursor.require(error.MissingText));
        },
        .agent_draft_get => {
            self.target_id = try positive(std.mem.span(try cursor.require(error.MissingTarget)));
        },
        .client_clipboard_copy => self.text = std.mem.span(try cursor.require(error.MissingText)),
        .client_open_link => self.text = std.mem.span(try cursor.require(error.MissingText)),
        .notification_dismiss => self.target_id = try positive(std.mem.span(try cursor.require(error.MissingTarget))),
        .client_copy_mode => {},
        .client_open_history => {},
        .client_open_goto => {},
        .agent_create => {},
        .workspace_list_collapse => {},
        .workspace_list_expand => {},
        .sidebar_resize => self.value = std.math.cast(u16, try positive(std.mem.span(try cursor.require(error.MissingWidth)))) orelse return error.InvalidWidth,
        .sidebar_hide => {},
        .sidebar_show => {},
        .sidebar_get => {},
        .pane_scroll => {
            self.target_id = try positive(std.mem.span(try cursor.require(error.MissingTarget)));
            self.value = std.fmt.parseInt(i32, std.mem.span(try cursor.require(error.MissingScrollDelta)), 10) catch return error.InvalidScrollDelta;
        },
        .pane_fullscreen => self.target_id = try positive(std.mem.span(try cursor.require(error.MissingTarget))),
        .pane_resize => {
            self.target_id = try positive(std.mem.span(try cursor.require(error.MissingTarget)));
            self.text = std.mem.span(try cursor.require(error.MissingPaneDirection));
            if (std.meta.stringToEnum(core.PaneDirection, self.text) == null) {
                return error.InvalidPaneDirection;
            }
        },
        .pane_focus => self.target_id = try positive(std.mem.span(try cursor.require(error.MissingTarget))),
        .pane_close => self.target_id = try positive(std.mem.span(try cursor.require(error.MissingTarget))),
        .pane_split => {
            self.target_id = try positive(std.mem.span(try cursor.require(error.MissingTarget)));
            self.text = std.mem.span(try cursor.require(error.MissingSplitAxis));
            if (!std.mem.eql(u8, self.text, "horizontal") and !std.mem.eql(u8, self.text, "vertical")) {
                return error.InvalidSplitAxis;
            }
        },
        .pane_create => {},
        .tab_previous => {},
        .tab_next => {},
        .tab_select => self.target_id = try positive(std.mem.span(try cursor.require(error.MissingTarget))),
        .workspace_select => self.target_id = try positive(std.mem.span(try cursor.require(error.MissingTarget))),
        .tab_create => {},
    }
    while (cursor.next()) |argument| {
        const arg = std.mem.span(argument);
        if (std.mem.eql(u8, arg, "--client") and self.client_id == 0) {
            self.client_id = try positive(std.mem.span(try cursor.require(error.MissingClientId)));
        } else if (std.mem.eql(u8, arg, "--label") and (self.action == .tab_create or self.action == .agent_create) and self.text.len == 0) {
            self.text = std.mem.span(try cursor.require(error.MissingLabel));
        } else if (std.mem.eql(u8, arg, "--work") and std.mem.startsWith(u8, @tagName(self.action), "agent_view_") and self.value == 0) {
            self.value = 1;
        } else if (std.mem.eql(u8, arg, "--section") and self.action == .config_show and self.text.len == 0) {
            self.text = std.mem.span(try cursor.require(error.MissingSection));
        } else if (std.mem.eql(u8, arg, "--index") and self.action == .config_show) {
            self.value = std.fmt.parseUnsigned(u16, std.mem.span(try cursor.require(error.MissingIndex)), 10) catch return error.InvalidIndex;
        } else if (std.mem.eql(u8, arg, "--json") and !self.json) {
            self.json = true;
        } else if (std.mem.eql(u8, arg, "--socket") and self.socket == null) {
            self.socket = try cursor.require(error.MissingSocketPath);
        } else {
            return error.UnknownClientCommandOption;
        }
    }

    if (self.client_id == 0) {
        return error.MissingClientId;
    }

    return self;
}

fn positive(value: []const u8) !u64 {
    const parsed = std.fmt.parseUnsigned(u64, value, 10) catch return error.InvalidTarget;
    if (parsed == 0) {
        return error.InvalidTarget;
    }

    return parsed;
}

test "routed commands require an explicit positive UI client and target" {
    try std.testing.expectError(error.MissingClientId, parse(&.{ "workspace", "select", "42" }));
    try std.testing.expectError(error.InvalidTarget, parse(&.{ "workspace", "select", "0", "--client", "7" }));
    const options = (try parse(&.{ "workspace", "select", "42", "--client", "7", "--json" })).?;
    try std.testing.expectEqual(@as(u64, 42), options.target_id);
    try std.testing.expectEqual(@as(u64, 7), options.client_id);
}
