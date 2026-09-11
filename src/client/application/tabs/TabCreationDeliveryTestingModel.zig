const ModelType = @import("../../model/Model.zig");
const TabLocationType = @import("telar-core").TabLocation;
const PaneIdType = @import("telar-core").PaneId;
const std = @import("std");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const TabCreationType = @import("../../model/TabCreation.zig");
const TestingModel = @This();

model: *ModelType,
previous: TabLocationType,
created: TabLocationType,
previous_root: PaneIdType,
previous_sibling: PaneIdType,
created_root: PaneIdType,

pub fn init() !TestingModel {
    const model = try std.testing.allocator.create(ModelType);
    errdefer std.testing.allocator.destroy(model);
    model.* = ModelType.init(std.testing.allocator, true);
    errdefer model.deinit();

    const workspace: WorkspaceLocationType = .{ .workspace = @enumFromInt(1) };
    const previous: TabLocationType = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const created: TabLocationType = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    const previous_root: PaneIdType = @enumFromInt(1);
    const previous_sibling: PaneIdType = @enumFromInt(2);
    const created_root: PaneIdType = @enumFromInt(3);
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

pub fn create(testing: *TestingModel) !TabCreationType {
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
