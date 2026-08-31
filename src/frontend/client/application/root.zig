//! Client application use cases.

pub const attach_pane = @import("attach_pane.zig");
pub const close_pane = @import("close_pane.zig");
pub const close_tab = @import("close_tab.zig");
pub const copy_mode = @import("copy_mode.zig");
pub const create_tab = @import("create_tab.zig");
pub const create_workspace = @import("create_workspace.zig");
pub const focus_pane = @import("focus_pane.zig");
pub const move_tab = @import("move_tab.zig");
pub const name_prompt = @import("name_prompt.zig");
pub const pane_input = @import("pane_input.zig");
pub const rename_tab = @import("rename_tab.zig");
pub const rename_workspace = @import("rename_workspace.zig");
pub const resize_pane = @import("resize_pane.zig");
pub const select_tab = @import("select_tab.zig");
pub const set_pane_viewport = @import("set_pane_viewport.zig");
pub const split_pane = @import("split_pane.zig");
pub const tab_snapshot = @import("tab_snapshot.zig");
pub const toggle_pane_fullscreen = @import("toggle_pane_fullscreen.zig");
pub const toggle_sidebar = @import("toggle_sidebar.zig");
pub const toggle_workspace_list = @import("toggle_workspace_list.zig");
pub const workspace_handoff = @import("workspace_handoff.zig");
pub const workspace_snapshot = @import("workspace_snapshot.zig");

test {
    _ = attach_pane;
    _ = close_pane;
    _ = close_tab;
    _ = copy_mode;
    _ = create_tab;
    _ = create_workspace;
    _ = focus_pane;
    _ = move_tab;
    _ = name_prompt;
    _ = pane_input;
    _ = rename_tab;
    _ = rename_workspace;
    _ = resize_pane;
    _ = select_tab;
    _ = set_pane_viewport;
    _ = split_pane;
    _ = tab_snapshot;
    _ = toggle_pane_fullscreen;
    _ = toggle_sidebar;
    _ = toggle_workspace_list;
    _ = workspace_handoff;
    _ = workspace_snapshot;
}
