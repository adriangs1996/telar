//! Bounded semantic actions produced by native and Lua keybindings.
//!
//! The input router stores these values directly. Strings, Lua closures and
//! plugin names are resolved while compiling configuration so routing remains
//! allocation-free and never retains configuration-owned memory.

const CommandTab = @import("CommandTab.zig");
const std = @import("std");

pub const SplitDirection = @import("../types/SplitDirection.zig").SplitDirection;
pub const Direction = @import("../types/InputDirection.zig").InputDirection;
pub const SidebarDirection = @import("../types/ActionSidebarDirection.zig").ActionSidebarDirection;
pub const TabMove = @import("../types/ActionTabMove.zig").ActionTabMove;
pub const ScrollDirection = @import("../types/ScrollDirection.zig").ScrollDirection;

pub const Action = @import("../types/Action.zig").Action;

test "built-in names compile to parameterized actions" {
    try std.testing.expectEqualDeep(
        Action{
            .split_pane = .horizontal,
        },
        try Action.parse("split-horizontal"),
    );
    try std.testing.expectEqualDeep(
        Action{
            .select_tab = 8,
        },
        try Action.parse("select-tab-9"),
    );
    try std.testing.expectEqualDeep(
        Action{
            .select_workspace = 4,
        },
        try Action.parse("select-workspace-5"),
    );
    try std.testing.expectEqualDeep(
        Action{
            .select_tab_offset = -1,
        },
        try Action.parse("previous-tab"),
    );
    try std.testing.expectEqualDeep(
        Action{
            .resize_pane = .up,
        },
        try Action.parse("resize-up"),
    );
    try std.testing.expectEqualDeep(
        Action.toggle_pane_fullscreen,
        try Action.parse("toggle-pane-fullscreen"),
    );
    try std.testing.expectEqualDeep(
        Action{
            .resize_sidebar = .right,
        },
        try Action.parse("resize-sidebar-right"),
    );
    try std.testing.expectEqual(Action.new_workspace, try Action.parse("new-workspace"));
    try std.testing.expectEqual(Action.rename_workspace, try Action.parse("rename-workspace"));
    try std.testing.expectEqual(Action.enter_copy_mode, try Action.parse("copy-mode"));
    try std.testing.expectEqualDeep(
        Action{
            .scroll_pane = .up,
        },
        try Action.parse("scroll-pane-up"),
    );
    try std.testing.expectEqualDeep(
        Action{
            .scroll_pane = .down,
        },
        try Action.parse("scroll-pane-down"),
    );
    try std.testing.expectError(error.UnknownAction, Action.parse("scroll-pane-left"));
    try std.testing.expectError(error.UnknownAction, Action.parse("select-tab-0"));
    try std.testing.expectError(error.UnknownAction, Action.parse("select-workspace-0"));
    try std.testing.expectError(error.UnknownAction, Action.parse("rename-pane"));
}

test "command tabs copy a bounded argv and derive their label" {
    const command = try CommandTab.init(&.{
        "/usr/local/bin/lazygit",
        "-p",
        ".",
    }, "");
    try std.testing.expectEqualStrings("/usr/local/bin/lazygit", command.argument(0));
    try std.testing.expectEqualStrings(".", command.argument(2));
    try std.testing.expectEqualStrings("lazygit", command.label());

    const labeled = try CommandTab.init(&.{
        "htop",
    }, "monitor");
    try std.testing.expectEqualStrings("monitor", labeled.label());

    try std.testing.expectError(error.InvalidCommand, CommandTab.init(&.{}, ""));
    try std.testing.expectError(error.InvalidCommand, CommandTab.init(&.{
        "",
    }, ""));
    try std.testing.expectError(error.InvalidCommand, CommandTab.init(&.{
        "a" ** 225,
    }, ""));
}
