const ClientUiContext = @This();
const frontend = @import("telar-frontend");
const std = @import("std");
const source_namespace = @import("main.zig");
tabs: frontend.tabs.Model,
screen: frontend.term.Screen,
view: frontend.client.View,

fn init(gpa: std.mem.Allocator, tab_count: usize) !ClientUiContext {
    std.debug.assert(tab_count >= 1 and tab_count <= frontend.tabs.max_tabs);
    var tabs = frontend.tabs.Model.init(gpa);
    errdefer tabs.deinit();
    const workspace: source_namespace.schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    try tabs.bootstrap(.{
        .pane_id = @enumFromInt(1),
        .location = .{ .workspace = workspace, .tab_id = @enumFromInt(1) },
        .size = .{ .cols = source_namespace.cols - source_namespace.sidebar_width, .rows = source_namespace.rows - 2 },
    });
    for (1..tab_count) |index| {
        var label_buffer: [source_namespace.schema.max_tab_label_bytes]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buffer, "tab-{d}", .{index + 1});
        _ = try tabs.addCreated(.{
            .location = .{
                .workspace = workspace,
                .tab_id = @enumFromInt(index + 1),
            },
            .position = @intCast(index),
            .label = label,
            .root_pane_id = @enumFromInt(index + 1),
        }, .{ .cols = source_namespace.cols - source_namespace.sidebar_width, .rows = source_namespace.rows - 2 });
    }
    var screen = try frontend.term.Screen.init(gpa, source_namespace.cols, source_namespace.rows);
    errdefer screen.deinit();
    var view = try frontend.client.View.init(gpa, source_namespace.cols, source_namespace.rows);
    errdefer view.deinit();
    const model = &tabs.active().?.model;
    var compositor = frontend.multiplexer.Compositor.init(gpa);
    defer compositor.deinit();
    _ = try compositor.render(.{
        .model = model,
        .screen = &screen,
        .input = .{ .area = view.workbench(), .palette = view.palette() },
    });
    _ = try view.render(&screen, .{ .tabs = &tabs, .model = model, .force = true });
    return .{ .tabs = tabs, .screen = screen, .view = view };
}

fn deinit(context: *ClientUiContext) void {
    context.view.deinit();
    context.screen.deinit();
    context.tabs.deinit();
}
