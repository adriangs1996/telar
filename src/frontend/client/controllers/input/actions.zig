//! Dispatches bounded semantic actions independently of their input source.

const parseKey_module = @import("telar-client").parseKey;
const Client = @import("../../Client.zig");
const Action = @import("telar-client").Action;
const ControlType = @import("telar-client").Control;
const NativeActionHandlerType = @import("telar-client").NativeActionHandler;
const copy_modes = @import("copy_modes.zig");
const ApplicationInputActionRoutingControl = @import("telar-client").ApplicationInputActionRoutingControl;
const ToggleAgentModeHandler = @import("telar-client").ToggleAgentModeHandler;
const name_prompts = @import("name_prompts.zig");
const workspace_handoffs = @import("../workspaces/workspace_handoffs.zig");
const client_layouts = @import("../../resources/client_layouts.zig");
const client_detachments = @import("../session/client_detachments.zig");
const history_palettes = @import("history_palettes.zig");
const suggestions = @import("suggestions.zig");
const notification_flow = @import("../notifications/notifications.zig");
const TabSelectionTarget = @import("telar-client").TabSelectionTarget;
const tab_selections = @import("../tabs/tab_selections.zig");
const PaneFocusTarget = @import("telar-client").PaneFocusTarget;
const pane_focus = @import("../panes/pane_focus.zig");
const DirectionType = @import("telar-client").Direction;
const std = @import("std");
const pane_inputs = @import("pane_inputs.zig");
const KeyType = @import("telar-client").Key;
const ScrollDirectionType = @import("telar-client").ScrollDirection;
const pane_mouse_input = @import("pane_mouse_inputs.zig");
const AxisType = @import("telar-client").Axis;
const pane_splits = @import("../panes/pane_splits.zig");
const WorkspaceLayoutSupportDirection = @import("telar-client").WorkspaceLayoutSupportDirection;
const pane_geometry = @import("../panes/pane_geometry.zig");
const sidebar_toggles = @import("../notifications/sidebar_toggles.zig");
const LayoutSidebarDirection = @import("telar-client").LayoutSidebarDirection;
const pane_closures = @import("../panes/pane_closures.zig");
const CommandTabType = @import("telar-client").CommandTab;
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
    var use_case: NativeActionHandlerType = .{
        .effects = .{
            .context = client,
            .leave_copy_mode = leaveCopyMode,
            .deliver = deliver,
        },
    };
    const control = try use_case.execute(value, .{
        .copy_mode_active = client.model.copyModeActive(),
    });

    return switch (control) {
        .continue_routing => .continue_routing,
        .stop => .stop,
    };
}

fn leaveCopyMode(raw_context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    _ = try copy_modes.leave(client);
}

fn deliver(raw_context: *anyopaque, value: Action) !ApplicationInputActionRoutingControl {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    switch (value) {
        .toggle_agent_mode => {
            var handler: ToggleAgentModeHandler = .{ .model = &client.model };
            handler.execute();
        },
        .scroll_pane => |direction| try scrollPane(client, direction),
        .split_pane => |direction| try beginSplit(client, switch (direction) {
            .horizontal => .horizontal,
            .vertical => .vertical,
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
    var use_case = tab_selections.selectionHandler(client);

    _ = try use_case.execute(.{ .target = target });
}

fn focusPane(client: *Client, target: PaneFocusTarget) !bool {
    var use_case = pane_focus.handler(client);

    return try use_case.execute(.{
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

fn beginSplit(client: *Client, axis: AxisType) !void {
    var use_case = pane_splits.requestHandler(client);
    _ = try use_case.execute(.{
        .axis = axis,
        .area = client.geometry().area,
    });
}

fn resizePane(client: *Client, direction: WorkspaceLayoutSupportDirection) !void {
    var use_case = pane_geometry.resizeHandler(client);

    _ = try use_case.execute(.{
        .direction = direction,
        .area = client.geometry().area,
    });
}

fn togglePaneFullscreen(client: *Client) !void {
    var use_case = pane_geometry.fullscreenHandler(client);

    _ = try use_case.execute(.{ .area = client.geometry().area });
}

fn toggleSidebar(client: *Client) !void {
    var use_case = sidebar_toggles.handler(client);

    _ = try use_case.execute();
}

fn resizeSidebar(client: *Client, direction: LayoutSidebarDirection) !void {
    var use_case = sidebar_toggles.resizeHandler(client);

    _ = try use_case.execute(.{ .direction = direction });
}

fn toggleWorkspaceList(client: *Client) void {
    _ = client.model.toggleWorkspaceList();
}

fn closeFocused(client: *Client) !void {
    var use_case = pane_closures.requestHandler(client);

    _ = try use_case.execute();
}

fn createCommandTab(client: *Client, command: *const CommandTabType) !void {
    var arguments: [CommandTabType.max_arguments][]const u8 = undefined;
    for (0..command.argument_count) |index| {
        arguments[index] = command.argument(index);
    }

    var use_case = tab_creations.requestHandler(client);
    _ = try use_case.execute(.{
        .label = command.label(),
        .arguments = arguments[0..command.argument_count],
    });
}

fn createTab(client: *Client) !void {
    var use_case = tab_creations.requestHandler(client);

    _ = try use_case.execute(.{});
}

fn closeTab(client: *Client) !void {
    var use_case = tab_closures.requestHandler(client);

    _ = try use_case.execute();
}

fn moveTab(client: *Client, direction: TabMoveDirectionType) !void {
    var use_case = tab_moves.requestHandler(client);

    _ = try use_case.execute(.{ .direction = direction });
}
