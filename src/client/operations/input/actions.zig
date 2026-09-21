//! Dispatches bounded semantic actions independently of their input source.

const parseKey_module = @import("../../input/chord.zig").parseKey;
const Client = @import("../../AttachedClient.zig");
const Action = @import("../../input/action.zig").Action;
const ControlType = @import("../../input/keybind.zig").Control;
const copy_modes = @import("copy_modes.zig");
const name_prompts = @import("name_prompts.zig");
const workspace_handoffs = @import("../workspaces/workspace_handoffs.zig");
const client_layouts = @import("../../resources/client_layouts.zig");
const client_detachments = @import("../session/client_detachments.zig");
const history_palettes = @import("history_palettes.zig");
const suggestions = @import("suggestions.zig");
const notification_flow = @import("../notifications/notifications.zig");
const TabSelectionTarget = @import("../../model/types.zig").TabSelectionTarget;
const tab_selections = @import("../tabs/tab_selections.zig");
const PaneFocusTarget = @import("../../model/types.zig").PaneFocusTarget;
const pane_focus = @import("../panes/pane_focus.zig");
const DirectionType = @import("../../input/action.zig").Direction;
const std = @import("std");
const pane_inputs = @import("pane_inputs.zig");
const KeyType = @import("../../input/Key.zig");
const ScrollDirectionType = @import("../../input/action.zig").ScrollDirection;
const pane_mouse_input = @import("pane_mouse_inputs.zig");
const pane_splits = @import("../panes/pane_splits.zig");
const WorkspaceLayoutSupportDirection = @import("../../workspace/layout_support.zig").Direction;
const pane_geometry = @import("../panes/pane_geometry.zig");
const sidebar_toggles = @import("../notifications/sidebar_toggles.zig");
const LayoutSidebarDirection = @import("../../layout/sidebar.zig").Direction;
const pane_closures = @import("../panes/pane_closures.zig");
const CommandTabType = @import("../../input/CommandTab.zig");
const tab_creations = @import("../tabs/tab_creations.zig");
const tab_closures = @import("../tabs/tab_closures.zig");
const TabMoveDirectionType = @import("telar-core").TabMoveDirection;
const tab_moves = @import("../tabs/tab_moves.zig");

const ctrl_h = parseKey_module("ctrl+h") catch unreachable;
const ctrl_j = parseKey_module("ctrl+j") catch unreachable;
const ctrl_k = parseKey_module("ctrl+k") catch unreachable;
const ctrl_l = parseKey_module("ctrl+l") catch unreachable;

/// Applies one native semantic action from host input, Lua or a plugin.
///
/// ```zig
/// if (try apply(client, action) == .stop) {
///     return;
/// }
/// ```
pub fn apply(client: *Client, value: Action) !ControlType {
    if (value != .enter_copy_mode and copy_modes.active(client)) {
        _ = try copy_modes.leave(client);
    }

    switch (value) {
        .toggle_thread_view => {
            _ = client.model.togglePaneSurface();
        },
        .scroll_pane => |direction| try scrollPane(client, direction),
        .split_pane => |direction| _ = try pane_splits.request(client, .{
            .axis = switch (direction) {
                .horizontal => .horizontal,
                .vertical => .vertical,
            },
            .area = client.geometry().area,
        }),
        .focus_pane => |direction| _ = try focusPane(client, .{ .direction = switch (direction) {
            .left => .left,
            .right => .right,
            .up => .up,
            .down => .down,
        } }),
        .navigate_pane => |direction| try navigatePane(client, direction),
        .resize_pane => |direction| try resizePane(client, switch (direction) {
            .left => .left,
            .right => .right,
            .up => .up,
            .down => .down,
        }),
        .toggle_pane_fullscreen => try togglePaneFullscreen(client),
        .toggle_sidebar => try toggleSidebar(client),
        .resize_sidebar => |direction| try resizeSidebar(client, switch (direction) {
            .left => .narrower,
            .right => .wider,
        }),
        .toggle_workspace_list => toggleWorkspaceList(client),
        .new_workspace => _ = name_prompts.beginWorkspaceCreate(client),
        .rename_workspace => _ = name_prompts.beginWorkspaceRename(client),
        .select_workspace => |position| _ = try workspace_handoffs.selectWorkspace(client, .{ .position = position }),
        .close_pane => try closeFocused(client),
        .new_tab => try createTab(client),
        .new_agent_tab => try @import("../agents/agent_threads.zig").create(client),
        .select_tab_offset => |offset| try selectTab(client, .{ .offset = offset }),
        .select_tab => |position| try selectTab(client, .{ .position = position }),
        .rename_tab => _ = name_prompts.beginActiveTabRename(client),
        .close_tab => try closeTab(client),
        .move_tab => |direction| try moveTab(client, switch (direction) {
            .previous => .previous,
            .next => .next,
        }),
        .detach => {
            try client_layouts.observe(client);
            try client_detachments.apply(client);

            return .stop;
        },
        .enter_copy_mode => _ = copy_modes.enter(client),
        .command_tab => |*command| try createCommandTab(client, command),
        .goto_picker => _ = name_prompts.beginGotoPicker(client),
        .history_palette => _ = try history_palettes.begin(client),
        .suggest_command => _ = try suggestions.begin(client),
        .notification => |*notification| _ = try notification_flow.requestDelivery(client, notification),
        .lua_callback, .lua_expr, .plugin => unreachable,
    }

    return .continue_routing;
}

fn selectTab(client: *Client, target: TabSelectionTarget) !void {
    _ = try tab_selections.select(client, .{ .target = target });
}

fn focusPane(client: *Client, target: PaneFocusTarget) !bool {
    return try pane_focus.apply(client, .{
        .target = target,
        .area = client.geometry().area,
    }) != null;
}

fn navigatePane(client: *Client, direction: DirectionType) !void {
    const key = navigationKey(direction);
    if (std.mem.eql(u8, client.model.focusedPaneForeground(), "nvim")) {
        _ = try pane_inputs.send(client, .{ .target = .focused, .source = .host, .payload = .{ .key = key } });
        return;
    }

    _ = try focusPane(client, .{ .direction = switch (direction) {
        .left => .left,
        .right => .right,
        .up => .up,
        .down => .down,
    } });
}

fn navigationKey(direction: DirectionType) KeyType {
    return switch (direction) {
        .left => ctrl_h,
        .right => ctrl_l,
        .up => ctrl_k,
        .down => ctrl_j,
    };
}

fn scrollPane(client: *Client, direction: ScrollDirectionType) !void {
    const model = client.model.activeTabModel() orelse return;

    _ = try pane_mouse_input.apply(
        client,
        model,
        .{ .focused_scroll = direction },
    );
}

fn resizePane(client: *Client, direction: WorkspaceLayoutSupportDirection) !void {
    _ = try pane_geometry.resize(client, .{
        .direction = direction,
        .area = client.geometry().area,
    });
}

fn togglePaneFullscreen(client: *Client) !void {
    _ = try pane_geometry.toggleFullscreen(client, .{ .area = client.geometry().area });
}

fn toggleSidebar(client: *Client) !void {
    _ = try sidebar_toggles.toggle(client);
}

fn resizeSidebar(client: *Client, direction: LayoutSidebarDirection) !void {
    _ = try sidebar_toggles.resize(client, .{ .direction = direction });
}

fn toggleWorkspaceList(client: *Client) void {
    _ = client.model.toggleWorkspaceList();
}

fn closeFocused(client: *Client) !void {
    _ = try pane_closures.request(client);
}

fn createCommandTab(client: *Client, command: *const CommandTabType) !void {
    var arguments: [CommandTabType.max_arguments][]const u8 = undefined;
    for (0..command.argument_count) |index| {
        arguments[index] = command.argument(index);
    }

    _ = try tab_creations.request(client, .{
        .label = command.label(),
        .arguments = arguments[0..command.argument_count],
    });
}

fn createTab(client: *Client) !void {
    _ = try tab_creations.request(client, .{});
}

fn closeTab(client: *Client) !void {
    _ = try tab_closures.request(client);
}

fn moveTab(client: *Client, direction: TabMoveDirectionType) !void {
    _ = try tab_moves.request(client, .{ .direction = direction });
}
