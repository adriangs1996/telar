const TestingModel = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("pane_paste.zig");
const std = @import("std");
model: *client_model.Model,
pane_id: source_namespace.schema.PaneId,

pub fn init(bracketed_paste: bool) !TestingModel {
    const model = try std.testing.allocator.create(client_model.Model);
    errdefer std.testing.allocator.destroy(model);
    model.* = client_model.Model.init(std.testing.allocator, true);
    errdefer model.deinit();

    const pane_id: source_namespace.schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(.{ .pane_id = pane_id, .location = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    }, .size = .{ .cols = 20, .rows = 5 } });
    model.workspace.findPane(pane_id).?.input_modes.bracketed_paste = bracketed_paste;

    return .{ .model = model, .pane_id = pane_id };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}
