//! Application use case for releasing every client authority tied to one
//! canonically retired pane.

const ModelType = @import("../../model/Model.zig");
const std = @import("std");
const TabLocationType = @import("telar-core").TabLocation;
const PaneIdType = @import("telar-core").PaneId;
const PaneResourceReleaseEffectCapture = @import("PaneResourceReleaseEffectCapture.zig");
const ReleasePaneResourcesHandler = @import("ReleasePaneResourcesHandler.zig");
const ReleasedResources = @import("ReleasedResources.zig");

test "ReleasePaneResourcesHandler retires exact pane authorities before graphics" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: PaneIdType = @enumFromInt(1);
    try model.workspace.bootstrap(.{ .pane_id = pane_id, .location = location, .size = .{ .cols = 20, .rows = 5 } });
    _ = model.beginPanePaste().?;
    _ = model.syncReportedPaneFocus().?;
    var capture: PaneResourceReleaseEffectCapture = .{ .model = &model };
    var handler: ReleasePaneResourcesHandler = .{
        .model = &model,
        .effects = capture.effects(),
    };

    const paste = handler.execute(pane_id);

    try std.testing.expectEqualDeep(ReleasedResources{
        .copy_mode = false,
        .pane_paste = true,
        .reported_focus = true,
    }, paste);
    try std.testing.expect(!model.panePasteActive());
    try std.testing.expect(model.reportedPaneFocus() == null);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(pane_id, capture.pane_id.?);
    try std.testing.expect(capture.observed_released);

    try std.testing.expect(model.enterCopyMode());
    _ = model.syncReportedPaneFocus().?;
    const copy = handler.execute(pane_id);

    try std.testing.expectEqualDeep(ReleasedResources{
        .copy_mode = true,
        .pane_paste = false,
        .reported_focus = true,
    }, copy);
    try std.testing.expect(!model.copyModeActive());
    try std.testing.expect(model.reportedPaneFocus() == null);
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    try std.testing.expect(capture.observed_released);
}

test "ReleasePaneResourcesHandler clears stale graphics for an unknown pane" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: PaneResourceReleaseEffectCapture = .{ .model = &model };
    var handler: ReleasePaneResourcesHandler = .{
        .model = &model,
        .effects = capture.effects(),
    };
    const pane_id: PaneIdType = @enumFromInt(9);

    try std.testing.expectEqualDeep(ReleasedResources{
        .copy_mode = false,
        .pane_paste = false,
        .reported_focus = false,
    }, handler.execute(pane_id));
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(pane_id, capture.pane_id.?);
    try std.testing.expect(capture.observed_released);
}
