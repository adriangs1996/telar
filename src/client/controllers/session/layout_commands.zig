const std = @import("std");
const core = @import("telar-core");
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
