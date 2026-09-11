const TestingModel = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("tab_creation_delivery.zig");
const std = @import("std");
model: *client_model.Model,
previous: source_namespace.schema.TabLocation,
created: source_namespace.schema.TabLocation,
previous_root: source_namespace.schema.PaneId,
previous_sibling: source_namespace.schema.PaneId,
created_root: source_namespace.schema.PaneId,

pub fn init() !TestingModel {
    const model = try std.testing.allocator.create(client_model.Model);
    errdefer std.testing.allocator.destroy(model);
    model.* = client_model.Model.init(std.testing.allocator, true);
    errdefer model.deinit();

    const workspace: source_namespace.schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const previous: source_namespace.schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const created: source_namespace.schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    const previous_root: source_namespace.schema.PaneId = @enumFromInt(1);
    const previous_sibling: source_namespace.schema.PaneId = @enumFromInt(2);
    const created_root: source_namespace.schema.PaneId = @enumFromInt(3);
    try model.workspace.bootstrap(.{ .pane_id = previous_root, .location = previous, .size = .{ .cols = 40, .rows = 10 } });
    try model.workspace.active().?.model.split(.{ .existing_pane = previous_root, .new_pane = previous_sibling, .location = previous, .axis = .horizontal, .area = .{ .w = 40, .h = 10 } });
    if (!model.workspace.active().?.model.focusPane(previous_root)) {
        return error.PreviousFocusNotRestored;
    }

    const pane = model.workspace.findPane(previous_root).?;
    pane.input_modes.bracketed_paste = true;
    pane.input_modes.focus_events = true;
    pane.pending_frame_id = 7;
    model.workspace.findPane(previous_sibling).?.pending_frame_id = 9;
    _ = model.beginPanePaste().?;
    _ = model.syncReportedPaneFocus().?;

    return .{
        .model = model,
        .previous = previous,
        .created = created,
        .previous_root = previous_root,
        .previous_sibling = previous_sibling,
        .created_root = created_root,
    };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}

pub fn create(testing: *TestingModel) !client_model.TabCreation {
    return testing.model.createTab(.{
        .created = .{
            .location = testing.created,
            .position = 1,
            .label = "created",
            .root_pane_id = testing.created_root,
        },
        .size = .{ .cols = 40, .rows = 10 },
    });
}
