const TabsModel = @import("telar-client").TabsModel;
const ScreenType = @import("telar-frontend").Screen;
const State = @import("telar-frontend").State;
const std = @import("std");
const max_tabs_per_workspace = @import("telar-core").max_tabs_per_workspace;
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const main = @import("main.zig");
const default_width = @import("telar-client").default_width;
const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const CompositorType = @import("telar-frontend").Compositor;
const ClientUiContext = @This();

tabs: TabsModel,
screen: ScreenType,
view: State,

pub fn init(gpa: std.mem.Allocator, tab_count: usize) !ClientUiContext {
    std.debug.assert(tab_count >= 1 and tab_count <= max_tabs_per_workspace);
    var tabs = TabsModel.init(gpa);
    errdefer tabs.deinit();
    const workspace: WorkspaceLocationType = .{ .workspace = @enumFromInt(1) };
    try tabs.bootstrap(.{
        .pane_id = @enumFromInt(1),
        .location = .{ .workspace = workspace, .tab_id = @enumFromInt(1) },
        .size = .{ .cols = main.cols - default_width, .rows = main.rows - 2 },
    });
    for (1..tab_count) |index| {
        var label_buffer: [max_tab_label_bytes_module]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buffer, "tab-{d}", .{index + 1});
        _ = try tabs.addCreated(.{
            .location = .{
                .workspace = workspace,
                .tab_id = @enumFromInt(index + 1),
            },
            .position = @intCast(index),
            .label = label,
            .root_pane_id = @enumFromInt(index + 1),
        }, .{ .cols = main.cols - default_width, .rows = main.rows - 2 });
    }
    var screen = try ScreenType.init(gpa, main.cols, main.rows);
    errdefer screen.deinit();
    var view = try State.init(gpa, main.cols, main.rows);
    errdefer view.deinit();
    const model = &tabs.active().?.model;
    var compositor = CompositorType.init(gpa);
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
