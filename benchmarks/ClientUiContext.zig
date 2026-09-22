const client = @import("telar-client");
const frontend = @import("telar-frontend");
const core = @import("telar-core");
const data = @import("model");
const std = @import("std");
const main = @import("main.zig");
const ClientUiContext = @This();

tabs: client.TabsModel,
screen: frontend.Screen,
view: frontend.State,

pub fn init(gpa: std.mem.Allocator, tab_count: usize) !ClientUiContext {
    std.debug.assert(tab_count >= 1 and tab_count <= core.max_tabs_per_workspace);
    var tabs = client.TabsModel.init(gpa);
    errdefer tabs.deinit();
    const workspace: core.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    try tabs.bootstrap(.{
        .pane_id = @enumFromInt(1),
        .location = .{ .workspace = workspace, .tab_id = @enumFromInt(1) },
        .size = .{ .cols = main.cols - data.sidebar.default_width, .rows = main.rows - 2 },
    });
    for (1..tab_count) |index| {
        var label_buffer: [core.max_tab_label_bytes]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buffer, "tab-{d}", .{index + 1});
        _ = try tabs.addCreated(.{
            .location = .{
                .workspace = workspace,
                .tab_id = @enumFromInt(index + 1),
            },
            .position = @intCast(index),
            .label = label,
            .root_pane_id = @enumFromInt(index + 1),
        }, .{ .cols = main.cols - data.sidebar.default_width, .rows = main.rows - 2 });
    }
    var screen = try frontend.Screen.init(gpa, main.cols, main.rows);
    errdefer screen.deinit();
    var view = try frontend.State.init(gpa, main.cols, main.rows);
    errdefer view.deinit();
    const model = &tabs.active().?.model;
    var compositor = frontend.Compositor.init(gpa);
    defer compositor.deinit();
    _ = try compositor.render(.{
        .model = model,
        .screen = &screen,
        .input = .{ .area = view.workbench(), .palette = view.palette() },
    });
    _ = try view.render(&screen, .{ .tabs = &tabs, .model = model, .force = true });
    return .{ .tabs = tabs, .screen = screen, .view = view };
}

pub fn deinit(context: *ClientUiContext) void {
    context.view.deinit();
    context.screen.deinit();
    context.tabs.deinit();
}
