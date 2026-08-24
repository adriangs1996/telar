//! Built-in keymap, kept declarative and separate from input dispatch.

const action = @import("action.zig");
const keybind = @import("keybind.zig");

pub const max_keys = 4;
pub const count = 25;
pub const Binding = keybind.Binding(action.Action, max_keys);

pub fn load() ![count]Binding {
    return .{
        try .parse(&.{ "ctrl+b", "%" }, .{ .split_pane = .horizontal }),
        try .parse(&.{ "ctrl+b", "\"" }, .{ .split_pane = .vertical }),
        try .parse(&.{ "ctrl+b", "left" }, .{ .focus_pane = .left }),
        try .parse(&.{ "ctrl+b", "right" }, .{ .focus_pane = .right }),
        try .parse(&.{ "ctrl+b", "up" }, .{ .focus_pane = .up }),
        try .parse(&.{ "ctrl+b", "down" }, .{ .focus_pane = .down }),
        try .parse(&.{ "ctrl+b", "s" }, .toggle_sidebar),
        try .parse(&.{ "ctrl+b", "x" }, .close_pane),
        try .parse(&.{ "ctrl+b", "d" }, .detach),
        try .parse(&.{ "ctrl+b", "c" }, .new_tab),
        try .parse(&.{ "ctrl+b", "n" }, .{ .select_tab_offset = 1 }),
        try .parse(&.{ "ctrl+b", "p" }, .{ .select_tab_offset = -1 }),
        try .parse(&.{ "ctrl+b", "1" }, .{ .select_tab = 0 }),
        try .parse(&.{ "ctrl+b", "2" }, .{ .select_tab = 1 }),
        try .parse(&.{ "ctrl+b", "3" }, .{ .select_tab = 2 }),
        try .parse(&.{ "ctrl+b", "4" }, .{ .select_tab = 3 }),
        try .parse(&.{ "ctrl+b", "5" }, .{ .select_tab = 4 }),
        try .parse(&.{ "ctrl+b", "6" }, .{ .select_tab = 5 }),
        try .parse(&.{ "ctrl+b", "7" }, .{ .select_tab = 6 }),
        try .parse(&.{ "ctrl+b", "8" }, .{ .select_tab = 7 }),
        try .parse(&.{ "ctrl+b", "9" }, .{ .select_tab = 8 }),
        try .parse(&.{ "ctrl+b", "T" }, .rename_tab),
        try .parse(&.{ "ctrl+b", "X" }, .close_tab),
        try .parse(&.{ "ctrl+b", "," }, .{ .move_tab = .previous }),
        try .parse(&.{ "ctrl+b", "." }, .{ .move_tab = .next }),
    };
}
