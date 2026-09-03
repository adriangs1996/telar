//! Bounded semantic actions produced by native and Lua keybindings.
//!
//! The input router stores these values directly. Strings, Lua closures and
//! plugin names are resolved while compiling configuration so routing remains
//! allocation-free and never retains configuration-owned memory.

const std = @import("std");
const core = @import("telar-core");

const schema = core.schema;

pub const CallbackRef = struct {
    generation: u64,
    id: u32,
};

pub const PluginAction = struct {
    plugin: u64,
    action: u64,
};

pub const SplitDirection = enum(u8) { horizontal, vertical };
pub const Direction = enum(u8) { left, right, up, down };
pub const SidebarDirection = enum(u8) { left, right };
pub const TabMove = enum(u8) { previous, next };

pub const Notification = struct {
    level: schema.NotificationLevel = .info,
    duration_ms: u32 = schema.default_notification_duration_ms,
    target: schema.NotificationTarget = .none,
    title_bytes: [schema.max_notification_title_bytes]u8 = @splat(0),
    title_len: u8,
    message_bytes: [schema.max_notification_message_bytes]u8 = @splat(0),
    message_len: u8,

    pub fn init(level: schema.NotificationLevel, duration_ms: u32, target: schema.NotificationTarget, title_text: []const u8, message_text: []const u8) !Notification {
        // Reuse the wire validator so Lua and plugins cannot construct a value
        // that the runtime will reject after the effect batch is committed.
        var validation_buffer: [
            1 + 8 + 1 + 4 + 1 + 8 + 2 +
                schema.max_notification_title_bytes + 2 +
                schema.max_notification_message_bytes
        ]u8 = undefined;
        _ = try schema.encodeShowNotification(&validation_buffer, .{
            .request_id = @enumFromInt(1),
            .notification = .{
                .level = level,
                .duration_ms = duration_ms,
                .target = target,
                .title = title_text,
                .message = message_text,
            },
        });
        var value: Notification = .{
            .level = level,
            .duration_ms = duration_ms,
            .target = target,
            .title_len = @intCast(title_text.len),
            .message_len = @intCast(message_text.len),
        };
        @memcpy(value.title_bytes[0..title_text.len], title_text);
        @memcpy(value.message_bytes[0..message_text.len], message_text);
        return value;
    }

    pub fn title(value: *const Notification) []const u8 {
        return value.title_bytes[0..value.title_len];
    }

    pub fn message(value: *const Notification) []const u8 {
        return value.message_bytes[0..value.message_len];
    }
};

/// A command opened in its own transient tab. The tab closes when the
/// command exits, like a popup that borrows tab machinery instead of
/// floating chrome.
pub const CommandTab = struct {
    pub const max_arguments = 8;
    pub const max_command_bytes = 224;
    pub const max_label_bytes = 32;

    argument_storage: [max_command_bytes]u8 = undefined,
    argument_lens: [max_arguments]u8 = undefined,
    argument_count: u8 = 0,
    label_storage: [max_label_bytes]u8 = undefined,
    label_len: u8 = 0,

    /// Copies a bounded argv and optional label into inline storage. The
    /// caps keep the Action union small enough for by-value keymaps. An
    /// empty label derives from the command's basename at render time.
    ///
    /// ```zig
    /// const command = try CommandTab.init(&.{"lazygit"}, "git");
    /// ```
    pub fn init(arguments: []const []const u8, tab_label: []const u8) !CommandTab {
        if (arguments.len == 0 or arguments.len > max_arguments) {
            return error.InvalidCommand;
        }
        if (tab_label.len > max_label_bytes) {
            return error.InvalidTabLabel;
        }

        var command: CommandTab = .{ .argument_count = @intCast(arguments.len) };
        var offset: usize = 0;
        for (arguments, 0..) |item, index| {
            if (item.len == 0 or offset + item.len > max_command_bytes) {
                return error.InvalidCommand;
            }
            if (std.mem.indexOfScalar(u8, item, 0) != null) {
                return error.InvalidCommand;
            }
            @memcpy(command.argument_storage[offset .. offset + item.len], item);
            command.argument_lens[index] = @intCast(item.len);
            offset += item.len;
        }

        @memcpy(command.label_storage[0..tab_label.len], tab_label);
        command.label_len = @intCast(tab_label.len);
        return command;
    }

    pub fn argument(command: *const CommandTab, index: usize) []const u8 {
        var offset: usize = 0;
        for (0..index) |prior| {
            offset += command.argument_lens[prior];
        }

        return command.argument_storage[offset .. offset + command.argument_lens[index]];
    }

    /// The configured label, or the command basename.
    ///
    /// ```zig
    /// const label = command.label();
    /// ```
    pub fn label(command: *const CommandTab) []const u8 {
        if (command.label_len != 0) {
            return command.label_storage[0..command.label_len];
        }

        return std.fs.path.basename(command.argument(0));
    }
};
pub const Action = union(enum) {
    split_pane: SplitDirection,
    focus_pane: Direction,
    navigate_pane: Direction,
    resize_pane: Direction,
    toggle_pane_fullscreen,
    toggle_sidebar,
    resize_sidebar: SidebarDirection,
    toggle_workspace_list,
    new_workspace,
    rename_workspace,
    select_workspace: u8,
    close_pane,
    new_tab,
    select_tab_offset: i8,
    select_tab: u8,
    rename_tab,
    close_tab,
    move_tab: TabMove,
    detach,
    goto_picker,
    history_palette,
    suggest_command,
    enter_copy_mode,
    command_tab: CommandTab,
    notification: Notification,
    lua_callback: CallbackRef,
    lua_expr: CallbackRef,
    plugin: PluginAction,

    /// Parses stable built-in action names used by configuration and tests.
    pub fn parse(name: []const u8) !Action {
        if (std.mem.eql(u8, name, "split-horizontal")) {
            return .{ .split_pane = .horizontal };
        }
        if (std.mem.eql(u8, name, "split-vertical")) {
            return .{ .split_pane = .vertical };
        }
        if (std.mem.eql(u8, name, "focus-left")) {
            return .{ .focus_pane = .left };
        }
        if (std.mem.eql(u8, name, "focus-right")) {
            return .{ .focus_pane = .right };
        }
        if (std.mem.eql(u8, name, "focus-up")) {
            return .{ .focus_pane = .up };
        }
        if (std.mem.eql(u8, name, "focus-down")) {
            return .{ .focus_pane = .down };
        }
        if (std.mem.eql(u8, name, "navigate-left")) {
            return .{ .navigate_pane = .left };
        }
        if (std.mem.eql(u8, name, "navigate-right")) {
            return .{ .navigate_pane = .right };
        }
        if (std.mem.eql(u8, name, "navigate-up")) {
            return .{ .navigate_pane = .up };
        }
        if (std.mem.eql(u8, name, "navigate-down")) {
            return .{ .navigate_pane = .down };
        }
        if (std.mem.eql(u8, name, "resize-left")) {
            return .{ .resize_pane = .left };
        }
        if (std.mem.eql(u8, name, "resize-right")) {
            return .{ .resize_pane = .right };
        }
        if (std.mem.eql(u8, name, "resize-up")) {
            return .{ .resize_pane = .up };
        }
        if (std.mem.eql(u8, name, "resize-down")) {
            return .{ .resize_pane = .down };
        }
        if (std.mem.eql(u8, name, "toggle-pane-fullscreen")) {
            return .toggle_pane_fullscreen;
        }
        if (std.mem.eql(u8, name, "toggle-sidebar")) {
            return .toggle_sidebar;
        }
        if (std.mem.eql(u8, name, "resize-sidebar-left")) {
            return .{ .resize_sidebar = .left };
        }
        if (std.mem.eql(u8, name, "resize-sidebar-right")) {
            return .{ .resize_sidebar = .right };
        }
        if (std.mem.eql(u8, name, "toggle-workspace-list")) {
            return .toggle_workspace_list;
        }
        if (std.mem.eql(u8, name, "new-workspace")) {
            return .new_workspace;
        }
        if (std.mem.eql(u8, name, "rename-workspace")) {
            return .rename_workspace;
        }
        if (std.mem.eql(u8, name, "close-pane")) {
            return .close_pane;
        }
        if (std.mem.eql(u8, name, "new-tab")) {
            return .new_tab;
        }
        if (std.mem.eql(u8, name, "next-tab")) {
            return .{ .select_tab_offset = 1 };
        }
        if (std.mem.eql(u8, name, "previous-tab")) {
            return .{ .select_tab_offset = -1 };
        }
        if (std.mem.eql(u8, name, "rename-tab")) {
            return .rename_tab;
        }
        if (std.mem.eql(u8, name, "close-tab")) {
            return .close_tab;
        }
        if (std.mem.eql(u8, name, "move-tab-previous")) {
            return .{ .move_tab = .previous };
        }
        if (std.mem.eql(u8, name, "move-tab-next")) {
            return .{ .move_tab = .next };
        }
        if (std.mem.eql(u8, name, "detach")) {
            return .detach;
        }
        if (std.mem.eql(u8, name, "copy-mode")) {
            return .enter_copy_mode;
        }
        if (std.mem.eql(u8, name, "goto-picker")) {
            return .goto_picker;
        }
        if (std.mem.eql(u8, name, "history-palette")) {
            return .history_palette;
        }
        if (std.mem.eql(u8, name, "suggest-command")) {
            return .suggest_command;
        }

        const prefix = "select-tab-";
        if (std.mem.startsWith(u8, name, prefix)) {
            const one_based = std.fmt.parseUnsigned(u8, name[prefix.len..], 10) catch
                return error.UnknownAction;
            if (one_based == 0) {
                return error.UnknownAction;
            }
            return .{ .select_tab = one_based - 1 };
        }
        const workspace_prefix = "select-workspace-";
        if (std.mem.startsWith(u8, name, workspace_prefix)) {
            const one_based = std.fmt.parseUnsigned(u8, name[workspace_prefix.len..], 10) catch
                return error.UnknownAction;
            if (one_based == 0) {
                return error.UnknownAction;
            }
            return .{ .select_workspace = one_based - 1 };
        }
        return error.UnknownAction;
    }
};

test "built-in names compile to parameterized actions" {
    try std.testing.expectEqualDeep(
        Action{ .split_pane = .horizontal },
        try Action.parse("split-horizontal"),
    );
    try std.testing.expectEqualDeep(
        Action{ .select_tab = 8 },
        try Action.parse("select-tab-9"),
    );
    try std.testing.expectEqualDeep(
        Action{ .select_workspace = 4 },
        try Action.parse("select-workspace-5"),
    );
    try std.testing.expectEqualDeep(
        Action{ .select_tab_offset = -1 },
        try Action.parse("previous-tab"),
    );
    try std.testing.expectEqualDeep(
        Action{ .resize_pane = .up },
        try Action.parse("resize-up"),
    );
    try std.testing.expectEqualDeep(
        Action.toggle_pane_fullscreen,
        try Action.parse("toggle-pane-fullscreen"),
    );
    try std.testing.expectEqualDeep(
        Action{ .resize_sidebar = .right },
        try Action.parse("resize-sidebar-right"),
    );
    try std.testing.expectEqual(Action.new_workspace, try Action.parse("new-workspace"));
    try std.testing.expectEqual(Action.rename_workspace, try Action.parse("rename-workspace"));
    try std.testing.expectEqual(Action.enter_copy_mode, try Action.parse("copy-mode"));
    try std.testing.expectError(error.UnknownAction, Action.parse("select-tab-0"));
    try std.testing.expectError(error.UnknownAction, Action.parse("select-workspace-0"));
    try std.testing.expectError(error.UnknownAction, Action.parse("rename-pane"));
}

test "command tabs copy a bounded argv and derive their label" {
    const command = try CommandTab.init(&.{ "/usr/local/bin/lazygit", "-p", "." }, "");
    try std.testing.expectEqualStrings("/usr/local/bin/lazygit", command.argument(0));
    try std.testing.expectEqualStrings(".", command.argument(2));
    try std.testing.expectEqualStrings("lazygit", command.label());

    const labeled = try CommandTab.init(&.{"htop"}, "monitor");
    try std.testing.expectEqualStrings("monitor", labeled.label());

    try std.testing.expectError(error.InvalidCommand, CommandTab.init(&.{}, ""));
    try std.testing.expectError(error.InvalidCommand, CommandTab.init(&.{""}, ""));
    try std.testing.expectError(error.InvalidCommand, CommandTab.init(&.{"a" ** 225}, ""));
}
