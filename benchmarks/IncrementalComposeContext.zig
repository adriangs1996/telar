const IncrementalComposeContext = @This();
const frontend = @import("telar-frontend");
const std = @import("std");
const Fixture = @import("Fixture.zig");
const source_namespace = @import("main.zig");
model: frontend.multiplexer.Model,
screen: frontend.term.Screen,
compositor: frontend.multiplexer.Compositor,
payloads: [2][]const u8,

fn init(gpa: std.mem.Allocator, fixture: *const Fixture) !IncrementalComposeContext {
    var model = frontend.multiplexer.Model.init(gpa);
    errdefer model.deinit();
    const location: source_namespace.schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try model.addRoot(.{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = source_namespace.cols, .rows = source_namespace.rows } });
    var screen = try frontend.term.Screen.init(gpa, source_namespace.cols, source_namespace.rows);
    errdefer screen.deinit();
    var compositor = frontend.multiplexer.Compositor.init(gpa);
    errdefer compositor.deinit();
    _ = try source_namespace.composeFullScreen(&compositor, &model, &screen);
    model.find(@enumFromInt(1)).?.applied_frame_id = 1;
    return .{
        .model = model,
        .screen = screen,
        .compositor = compositor,
        .payloads = fixture.sparse_payloads,
    };
}

fn deinit(context: *IncrementalComposeContext) void {
    context.compositor.deinit();
    context.screen.deinit();
    context.model.deinit();
}
