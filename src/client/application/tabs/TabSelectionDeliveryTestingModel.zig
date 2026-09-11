const ModelType = @import("../../model/Model.zig");
const TabLocationType = @import("telar-core").TabLocation;
const PaneIdType = @import("telar-core").PaneId;
const std = @import("std");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const RectType = @import("telar-core").Rect;
const TabSelectionType = @import("../../model/TabSelection.zig");
const TestingModel = @This();

model: *ModelType,
previous: TabLocationType,
selected: TabLocationType,
previous_root: PaneIdType,
previous_sibling: PaneIdType,
selected_root: PaneIdType,
selected_sibling: PaneIdType,

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
    const selected: TabLocationType = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    const previous_root: PaneIdType = @enumFromInt(1);
    const previous_sibling: PaneIdType = @enumFromInt(2);
    const selected_root: PaneIdType = @enumFromInt(3);
    const selected_sibling: PaneIdType = @enumFromInt(4);
    const area: RectType = .{ .w = 40, .h = 10 };
    try model.workspace.bootstrap(.{ .pane_id = previous_root, .location = previous, .size = .{ .cols = 40, .rows = 10 } });
    try model.workspace.active().?.model.split(.{ .existing_pane = previous_root, .new_pane = previous_sibling, .location = previous, .axis = .horizontal, .area = area });
    if (!model.workspace.active().?.model.focusPane(previous_root)) {
        return error.PreviousFocusNotRestored;
    }

    const root = model.workspace.findPane(previous_root).?;
    root.input_modes.bracketed_paste = true;
    root.input_modes.focus_events = true;
    _ = model.beginPanePaste().?;
    _ = model.syncReportedPaneFocus().?;

    const selected_tab = try model.workspace.addCreated(.{
        .location = selected,
        .position = 1,
        .label = "selected",
        .root_pane_id = selected_root,
    }, .{ .cols = 40, .rows = 10 });
    try selected_tab.model.split(.{ .existing_pane = selected_root, .new_pane = selected_sibling, .location = selected, .axis = .horizontal, .area = area });
    var selected_panes = selected_tab.model.paneIterator();
    while (selected_panes.next()) |pane| {
        pane.attached = false;
    }

    if (!model.workspace.select(previous.tab_id)) {
        return error.PreviousTabNotRestored;
    }

    return .{
        .model = model,
        .previous = previous,
        .selected = selected,
        .previous_root = previous_root,
        .previous_sibling = previous_sibling,
        .selected_root = selected_root,
        .selected_sibling = selected_sibling,
    };
}

pub fn deinit(testing: *TestingModel) void {
    testing.model.deinit();
    std.testing.allocator.destroy(testing.model);
}

pub fn select(testing: *TestingModel) !TabSelectionType {
    return (try testing.model.selectTab(.{ .tab_id = testing.selected.tab_id })).?;
}
