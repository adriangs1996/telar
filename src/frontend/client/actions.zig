//! Dispatches bounded semantic actions independently of their input source.

const core = @import("telar-core");
const input = @import("../input/root.zig");
const workspace = @import("../workspace/root.zig");
const client_application = @import("application/root.zig");

const Client = @import("client.zig");
const client_detachments = @import("client_detachments.zig");
const copy_modes = @import("copy_modes.zig");
const name_prompts = @import("name_prompts.zig");
const notification_flow = @import("notifications.zig");
const pane_closures = @import("pane_closures.zig");
const pane_focus = @import("pane_focus.zig");
const pane_geometry = @import("pane_geometry.zig");
const pane_splits = @import("pane_splits.zig");
const sidebar_toggles = @import("sidebar_toggles.zig");
const tab_closures = @import("tab_closures.zig");
const tab_creations = @import("tab_creations.zig");
const tab_moves = @import("tab_moves.zig");
const tab_selections = @import("tab_selections.zig");
const workspace_handoffs = @import("workspace_handoffs.zig");

const Action = input.action.Action;
const keybind = input.keybind;
const layout = workspace.layout;
const native_action = client_application.native_action;
const schema = core.schema;

/// Applies one native semantic action from host input, Lua or a plugin.
///
/// ```zig
/// if (try apply(client, action) == .stop) {
///     return;
/// }
/// ```
pub fn apply(client: *Client, value: Action) !keybind.Control {
    var use_case: native_action.NativeActionHandler = .{
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

fn deliver(raw_context: *anyopaque, value: Action) !native_action.Control {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    switch (value) {
        .split_pane => |direction| try beginSplit(client, switch (direction) {
            .horizontal => .horizontal,
            .vertical => .vertical,
        }),
        .focus_pane => |direction| try focusPane(client, .{ .direction = switch (direction) {
            .left => .left,
            .right => .right,
            .up => .up,
            .down => .down,
        } }),
        .resize_pane => |direction| try resizePane(client, switch (direction) {
            .left => .left,
            .right => .right,
            .up => .up,
            .down => .down,
        }),
        .toggle_pane_fullscreen => try togglePaneFullscreen(client),
        .toggle_sidebar => try toggleSidebar(client),
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
            try client_detachments.apply(client);

            return .stop;
        },
        .enter_copy_mode => _ = copy_modes.enter(client),
        .notification => |*notification| _ = try notification_flow.requestDelivery(client, notification),
        .lua_callback, .lua_expr, .plugin => unreachable,
    }

    return .continue_routing;
}

fn selectTab(client: *Client, target: tab_selections.Target) !void {
    var use_case = tab_selections.selectionHandler(client);

    _ = try use_case.execute(.{ .target = target });
}

fn focusPane(client: *Client, target: pane_focus.Target) !void {
    var use_case = pane_focus.handler(client);

    _ = try use_case.execute(.{
        .target = target,
        .area = client.view.workbench(),
    });
}

fn beginSplit(client: *Client, axis: layout.Axis) !void {
    var use_case = pane_splits.requestHandler(client);
    _ = try use_case.execute(.{
        .axis = axis,
        .area = client.view.workbench(),
    });
}

fn resizePane(client: *Client, direction: layout.Direction) !void {
    var use_case = pane_geometry.resizeHandler(client);

    _ = try use_case.execute(.{
        .direction = direction,
        .area = client.view.workbench(),
    });
}

fn togglePaneFullscreen(client: *Client) !void {
    var use_case = pane_geometry.fullscreenHandler(client);

    _ = try use_case.execute(.{ .area = client.view.workbench() });
}

fn toggleSidebar(client: *Client) !void {
    var use_case = sidebar_toggles.handler(client);

    _ = try use_case.execute();
}

fn toggleWorkspaceList(client: *Client) void {
    _ = client.model.toggleWorkspaceList();
}

fn closeFocused(client: *Client) !void {
    var use_case = pane_closures.requestHandler(client);

    _ = try use_case.execute();
}

fn createTab(client: *Client) !void {
    var use_case = tab_creations.requestHandler(client);

    _ = try use_case.execute(.{});
}

fn closeTab(client: *Client) !void {
    var use_case = tab_closures.requestHandler(client);

    _ = try use_case.execute();
}

fn moveTab(client: *Client, direction: schema.TabMoveDirection) !void {
    var use_case = tab_moves.requestHandler(client);

    _ = try use_case.execute(.{ .direction = direction });
}
