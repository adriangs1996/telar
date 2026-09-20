const std = @import("std");
const core = @import("telar-core");
const Layout = @import("../../workspace/WorkspaceLayout.zig");
const Handler = @import("../../application/panes/ApplyPaneLayoutHandler.zig");
const pane_focus = @import("../panes/pane_focus.zig");
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const Client = @import("../../AttachedClient.zig");

/// Exports the active tab with stable pane identities. Example: `try layout_commands.get(client, reply);`
pub fn get(client: *const Client, reply: *core.ClientCommand) !void {
    const tab = client.model.workspace.activeConst() orelse return error.NoActiveTab;
    const focused = tab.model.layout.focused() orelse return error.NoFocusedPane;
    var nodes: [core.max_client_layout_nodes]core.ClientLayoutNode = undefined;
    const tabs = [_]core.ClientTabLayout{.{
        .location = tab.location,
        .focused_pane = focused,
        .fullscreen = tab.model.layout.isFullscreen(),
        .workspace_active = true,
        .nodes = tab.model.layout.clientLayoutNodes(&nodes),
    }};
    var buffer: [core.ClientCommand.capacity / 2]u8 = undefined;
    const encoded = try core.encodeClientLayoutSnapshot(&buffer, .{
        .restored = true,
        .sidebar_visible = client.model.sidebarVisible(),
        .sidebar_width = client.model.sidebarWidth(),
        .workspace_list_collapsed = client.model.workspaceListCollapsed(),
        .active_tab = tab.location,
        .tabs = &tabs,
    });
    const text = try std.fmt.bufPrint(&reply.bytes, "{x}", .{encoded});
    reply.length = @intCast(text.len);
    reply.status = .applied;
}

const Model = @import("../../model/Model.zig");
test "layout export decodes to the same active pane and split tree" {
    var client: Client = undefined;
    client.model = Model.init(std.testing.allocator, true);
    defer client.model.deinit();
    const location: core.TabLocation = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(2) };
    try client.model.workspace.bootstrap(.{ .pane_id = @enumFromInt(3), .location = location, .size = .{ .cols = 80, .rows = 24 } });
    var reply: core.ClientCommand = .{ .request_id = @enumFromInt(5), .route = .{ .id = 7, .generation = 9 }, .action = .layout_get };
    try get(&client, &reply);
    var bytes: [core.ClientCommand.capacity / 2]u8 = undefined;
    const decoded = try core.decodeServer(try std.fmt.hexToBytes(&bytes, reply.text()));
    try std.testing.expectEqualDeep(location, decoded.client_layout_snapshot.active_tab.?);
    var tabs = decoded.client_layout_snapshot.tabs();
    const tab = (try tabs.next()).?;
    try std.testing.expectEqual(@as(core.PaneId, @enumFromInt(3)), tab.focused_pane);
    try std.testing.expect(try tabs.next() == null);
}

/// Decodes one owned token before invoking the layout application boundary. Example: `try layout_commands.apply(client, reply);`
pub fn apply(client: *Client, reply: *core.ClientCommand) !void {
    if (request_lifecycle.busy(client)) {
        return error.ClientBusy;
    }

    var bytes: [core.ClientCommand.capacity / 2]u8 = undefined;
    const encoded = try std.fmt.hexToBytes(&bytes, reply.text());
    const message = try core.decodeServer(encoded);
    if (message != .client_layout_snapshot) {
        return error.InvalidLayoutToken;
    }

    const snapshot = message.client_layout_snapshot;
    if (!snapshot.restored or snapshot.tab_count != 1 or snapshot.active_tab == null) {
        return error.InvalidLayoutToken;
    }

    var tabs = snapshot.tabs();
    const tab = (try tabs.next()) orelse return error.InvalidLayoutToken;
    if (!std.meta.eql(tab.location, snapshot.active_tab.?)) {
        return error.InvalidLayoutToken;
    }

    var ids: [core.max_panes_per_tab]core.PaneId = undefined;
    var count: usize = 0;
    var nodes = tab.nodes();
    while (try nodes.next()) |node| {
        if (node == .pane) {
            if (count == ids.len) {
                return error.InvalidLayoutToken;
            }

            ids[count] = node.pane.id;
            count += 1;
        }
    }

    var handler: Handler = .{ .model = &client.model, .effects = pane_focus.handler(client).effects };
    try handler.execute(.{ .location = tab.location, .layout = try Layout.fromClientLayout(tab), .panes = .{ .ids = ids[0..count], .focused = tab.focused_pane }, .area = client.geometry().area });
    reply.length = 0;
    reply.status = .applied;
}
