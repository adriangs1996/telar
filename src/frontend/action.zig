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
pub const TabMove = enum(u8) { previous, next };

pub const Notification = struct {
    level: schema.NotificationLevel = .info,
    duration_ms: u32 = schema.default_notification_duration_ms,
    target: schema.NotificationTarget = .none,
    title_bytes: [schema.max_notification_title_bytes]u8 = @splat(0),
    title_len: u8,
    message_bytes: [schema.max_notification_message_bytes]u8 = @splat(0),
    message_len: u8,

    pub fn init(
        level: schema.NotificationLevel,
        duration_ms: u32,
        target: schema.NotificationTarget,
        title_text: []const u8,
        message_text: []const u8,
    ) !Notification {
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

pub const Action = union(enum) {
    split_pane: SplitDirection,
    focus_pane: Direction,
    resize_pane: Direction,
    toggle_pane_fullscreen,
    toggle_sidebar,
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
    enter_copy_mode,
    notification: Notification,
    lua_callback: CallbackRef,
    lua_expr: CallbackRef,
    plugin: PluginAction,

    /// Parses stable built-in action names used by configuration and tests.
    pub fn parse(name: []const u8) !Action {
        if (std.mem.eql(u8, name, "split-horizontal"))
            return .{ .split_pane = .horizontal };
        if (std.mem.eql(u8, name, "split-vertical"))
            return .{ .split_pane = .vertical };
        if (std.mem.eql(u8, name, "focus-left"))
            return .{ .focus_pane = .left };
        if (std.mem.eql(u8, name, "focus-right"))
            return .{ .focus_pane = .right };
        if (std.mem.eql(u8, name, "focus-up"))
            return .{ .focus_pane = .up };
        if (std.mem.eql(u8, name, "focus-down"))
            return .{ .focus_pane = .down };
        if (std.mem.eql(u8, name, "resize-left"))
            return .{ .resize_pane = .left };
        if (std.mem.eql(u8, name, "resize-right"))
            return .{ .resize_pane = .right };
        if (std.mem.eql(u8, name, "resize-up"))
            return .{ .resize_pane = .up };
        if (std.mem.eql(u8, name, "resize-down"))
            return .{ .resize_pane = .down };
        if (std.mem.eql(u8, name, "toggle-pane-fullscreen"))
            return .toggle_pane_fullscreen;
        if (std.mem.eql(u8, name, "toggle-sidebar")) return .toggle_sidebar;
        if (std.mem.eql(u8, name, "toggle-workspace-list")) return .toggle_workspace_list;
        if (std.mem.eql(u8, name, "new-workspace")) return .new_workspace;
        if (std.mem.eql(u8, name, "rename-workspace")) return .rename_workspace;
        if (std.mem.eql(u8, name, "close-pane")) return .close_pane;
        if (std.mem.eql(u8, name, "new-tab")) return .new_tab;
        if (std.mem.eql(u8, name, "next-tab"))
            return .{ .select_tab_offset = 1 };
        if (std.mem.eql(u8, name, "previous-tab"))
            return .{ .select_tab_offset = -1 };
        if (std.mem.eql(u8, name, "rename-tab")) return .rename_tab;
        if (std.mem.eql(u8, name, "close-tab")) return .close_tab;
        if (std.mem.eql(u8, name, "move-tab-previous"))
            return .{ .move_tab = .previous };
        if (std.mem.eql(u8, name, "move-tab-next"))
            return .{ .move_tab = .next };
        if (std.mem.eql(u8, name, "detach")) return .detach;
        if (std.mem.eql(u8, name, "copy-mode")) return .enter_copy_mode;

        const prefix = "select-tab-";
        if (std.mem.startsWith(u8, name, prefix)) {
            const one_based = std.fmt.parseUnsigned(u8, name[prefix.len..], 10) catch
                return error.UnknownAction;
            if (one_based == 0) return error.UnknownAction;
            return .{ .select_tab = one_based - 1 };
        }
        const workspace_prefix = "select-workspace-";
        if (std.mem.startsWith(u8, name, workspace_prefix)) {
            const one_based = std.fmt.parseUnsigned(u8, name[workspace_prefix.len..], 10) catch
                return error.UnknownAction;
            if (one_based == 0) return error.UnknownAction;
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
    try std.testing.expectEqual(Action.new_workspace, try Action.parse("new-workspace"));
    try std.testing.expectEqual(Action.rename_workspace, try Action.parse("rename-workspace"));
    try std.testing.expectEqual(Action.enter_copy_mode, try Action.parse("copy-mode"));
    try std.testing.expectError(error.UnknownAction, Action.parse("select-tab-0"));
    try std.testing.expectError(error.UnknownAction, Action.parse("select-workspace-0"));
    try std.testing.expectError(error.UnknownAction, Action.parse("rename-pane"));
}
