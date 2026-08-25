//! Built-in keymap, kept declarative and separate from input dispatch.

const action = @import("action.zig");
const config_model = @import("config_model.zig");
const keybind = @import("keybind.zig");

pub const max_keys = config_model.max_binding_keys;
pub const count = 33;
pub const Binding = keybind.Binding(action.Action, max_keys);

pub fn load(prefix: keybind.Key) ![count]Binding {
    return .{
        try prefixed(prefix, "%", .{ .split_pane = .horizontal }),
        try prefixed(prefix, "\"", .{ .split_pane = .vertical }),
        try prefixed(prefix, "left", .{ .focus_pane = .left }),
        try prefixed(prefix, "right", .{ .focus_pane = .right }),
        try prefixed(prefix, "up", .{ .focus_pane = .up }),
        try prefixed(prefix, "down", .{ .focus_pane = .down }),
        try prefixed(prefix, "shift+left", .{ .resize_pane = .left }),
        try prefixed(prefix, "shift+right", .{ .resize_pane = .right }),
        try prefixed(prefix, "shift+up", .{ .resize_pane = .up }),
        try prefixed(prefix, "shift+down", .{ .resize_pane = .down }),
        try prefixed(prefix, "z", .toggle_pane_fullscreen),
        try prefixed(prefix, "s", .toggle_sidebar),
        try prefixed(prefix, "w", .toggle_workspace_list),
        try prefixed(prefix, "N", .new_workspace),
        try prefixed(prefix, "W", .rename_workspace),
        try prefixed(prefix, "x", .close_pane),
        try prefixed(prefix, "d", .detach),
        try prefixed(prefix, "c", .new_tab),
        try prefixed(prefix, "n", .{ .select_tab_offset = 1 }),
        try prefixed(prefix, "p", .{ .select_tab_offset = -1 }),
        try prefixed(prefix, "1", .{ .select_tab = 0 }),
        try prefixed(prefix, "2", .{ .select_tab = 1 }),
        try prefixed(prefix, "3", .{ .select_tab = 2 }),
        try prefixed(prefix, "4", .{ .select_tab = 3 }),
        try prefixed(prefix, "5", .{ .select_tab = 4 }),
        try prefixed(prefix, "6", .{ .select_tab = 5 }),
        try prefixed(prefix, "7", .{ .select_tab = 6 }),
        try prefixed(prefix, "8", .{ .select_tab = 7 }),
        try prefixed(prefix, "9", .{ .select_tab = 8 }),
        try prefixed(prefix, "T", .rename_tab),
        try prefixed(prefix, "X", .close_tab),
        try prefixed(prefix, ",", .{ .move_tab = .previous }),
        try prefixed(prefix, ".", .{ .move_tab = .next }),
    };
}

fn prefixed(prefix: keybind.Key, suffix: []const u8, action_value: action.Action) !Binding {
    return .init(&.{ prefix, try keybind.parseKey(suffix) }, action_value);
}
