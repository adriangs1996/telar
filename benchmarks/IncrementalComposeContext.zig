const data = @import("model");
const client = @import("telar-client");
const frontend = @import("telar-frontend");
const core = @import("telar-core");
const std = @import("std");
const Fixture = @import("Fixture.zig");
const main = @import("main.zig");
const IncrementalComposeContext = @This();

model: data.Model,
screen: frontend.Screen,
compositor: frontend.Compositor,
payloads: [2][]const u8,

pub fn init(gpa: std.mem.Allocator, fixture: *const Fixture) !IncrementalComposeContext {
    var model = data.Model.init(gpa, true);
    errdefer model.deinit();
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    try data.workspace_handoff.bootstrap(&model, .{ .pane_id = @enumFromInt(1), .location = location, .size = .{ .cols = main.cols, .rows = main.rows } });
    var screen = try frontend.Screen.init(gpa, main.cols, main.rows);
    errdefer screen.deinit();
    var compositor = frontend.Compositor.init(gpa);
    errdefer compositor.deinit();
    _ = try main.composeFullScreen(&compositor, &model, 0, &screen);
    model.panes.find(@enumFromInt(1)).?.applied_frame_id = 1;
    return .{
        .model = model,
        .screen = screen,
        .compositor = compositor,
        .payloads = fixture.sparse_payloads,
    };
}

pub fn deinit(context: *IncrementalComposeContext) void {
    context.compositor.deinit();
    context.screen.deinit();
    context.model.deinit();
}
