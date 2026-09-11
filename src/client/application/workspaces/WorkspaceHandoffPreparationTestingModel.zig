const TestingModel = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("workspace_handoff_preparation.zig");
const std = @import("std");
model: *client_model.Model,
root: source_namespace.schema.PaneId,
sibling: source_namespace.schema.PaneId,
other_root: source_namespace.schema.PaneId,

pub fn init() !TestingModel {
    const model = try std.testing.allocator.create(client_model.Model);
    errdefer std.testing.allocator.destroy(model);
    model.* = client_model.Model.init(std.testing.allocator, true);
    errdefer model.deinit();

    const workspace: source_namespace.schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const active: source_namespace.schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const other: source_namespace.schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    const root: source_namespace.schema.PaneId = @enumFromInt(1);
    const sibling: source_namespace.schema.PaneId = @enumFromInt(2);
    const other_root: source_namespace.schema.PaneId = @enumFromInt(3);
    try model.workspace.bootstrap(.{ .pane_id = root, .location = active, .size = .{ .cols = 40, .rows = 10 } });
    try model.workspace.active().?.model.split(.{ .existing_pane = root, .new_pane = sibling, .location = active, .axis = .horizontal, .area = .{ .w = 40, .h = 10 } });
    _ = try model.workspace.addCreated(.{
        .location = other,
        .position = 1,
        .label = "other",
        .root_pane_id = other_root,
    }, .{ .cols = 40, .rows = 10 });
    if (!model.workspace.select(active.tab_id)) {
        return error.ActiveTabNotRestored;
    }
    if (!model.workspace.active().?.model.focusPane(root)) {
        return error.ActiveFocusNotRestored;
    }

    const root_pane = model.workspace.findPane(root).?;
    root_pane.input_modes.bracketed_paste = true;
    root_pane.input_modes.focus_events = true;
    model.workspace.findPane(sibling).?.attached = false;
    _ = model.beginPanePaste().?;
    _ = model.syncReportedPaneFocus().?;

    return .{
        .model = model,
        .root = root,
        .sibling = sibling,
        .other_root = other_root,
    };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}
