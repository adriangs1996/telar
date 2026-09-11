const TestingModel = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("tab_close_preparation.zig");
const std = @import("std");
model: *client_model.Model,
location: source_namespace.schema.TabLocation,
root: source_namespace.schema.PaneId,
sibling: source_namespace.schema.PaneId,

pub fn init() !TestingModel {
    const model = try std.testing.allocator.create(client_model.Model);
    errdefer std.testing.allocator.destroy(model);
    model.* = client_model.Model.init(std.testing.allocator, true);
    errdefer model.deinit();

    const location: source_namespace.schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const root: source_namespace.schema.PaneId = @enumFromInt(1);
    const sibling: source_namespace.schema.PaneId = @enumFromInt(2);
    try model.workspace.bootstrap(.{ .pane_id = root, .location = location, .size = .{ .cols = 40, .rows = 10 } });
    try model.workspace.active().?.model.split(.{ .existing_pane = root, .new_pane = sibling, .location = location, .axis = .horizontal, .area = .{ .w = 40, .h = 10 } });
    if (!model.workspace.active().?.model.focusPane(root)) {
        return error.FocusNotChanged;
    }

    const root_pane = model.workspace.findPane(root).?;
    root_pane.input_modes.bracketed_paste = true;
    root_pane.input_modes.focus_events = true;
    model.workspace.findPane(sibling).?.attached = false;
    _ = model.beginPanePaste().?;
    _ = model.syncReportedPaneFocus().?;

    return .{
        .model = model,
        .location = location,
        .root = root,
        .sibling = sibling,
    };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}
