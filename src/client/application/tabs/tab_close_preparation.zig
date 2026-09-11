//! Application policy for reserving every bounded resource required by one
//! provisional tab closure before it produces effects.

const PaneIdType = @import("telar-core").PaneId;
const TabClosePreparationTestingModel = @import("TabClosePreparationTestingModel.zig");
const TabClosePreparationCapture = @import("TabClosePreparationCapture.zig");
const std = @import("std");
const TabLocationType = @import("telar-core").TabLocation;

pub const Event = union(enum) {
    ensure_requests: u64,
    attachment_pending: PaneIdType,
    available_deliveries,
};

test "PrepareTabCloseHandler accepts the exact required capacity without effects" {
    var testing = try TabClosePreparationTestingModel.init();
    defer testing.deinit();
    var capture: TabClosePreparationCapture = .{
        .pending_pane = testing.sibling,
        .available = 5,
    };
    const handler = capture.handler();

    try handler.execute(testing.model, testing.location);

    try std.testing.expectEqualDeep(&[_]Event{
        .{ .ensure_requests = 2 },
        .{ .attachment_pending = testing.root },
        .{ .attachment_pending = testing.sibling },
        .available_deliveries,
    }, capture.eventSlice());
    try std.testing.expect(testing.model.panePasteActive());
    try std.testing.expect(testing.model.reportedPaneFocus() != null);
    try std.testing.expect(testing.model.workspace.findPane(testing.root).?.attached);
    try std.testing.expect(!testing.model.workspace.findPane(testing.sibling).?.attached);
}

test "PrepareTabCloseHandler rejects insufficient delivery capacity without effects" {
    var testing = try TabClosePreparationTestingModel.init();
    defer testing.deinit();
    var capture: TabClosePreparationCapture = .{
        .pending_pane = testing.sibling,
        .available = 4,
    };
    const handler = capture.handler();

    try std.testing.expectError(error.ClientOutboxFull, handler.execute(testing.model, testing.location));

    try std.testing.expectEqual(@as(usize, 4), capture.event_count);
    try std.testing.expect(testing.model.panePasteActive());
    try std.testing.expect(testing.model.reportedPaneFocus() != null);
    try std.testing.expect(testing.model.workspace.findPane(testing.root).?.attached);
}

test "PrepareTabCloseHandler stops on request exhaustion before delivery queries" {
    var testing = try TabClosePreparationTestingModel.init();
    defer testing.deinit();
    var capture: TabClosePreparationCapture = .{
        .pending_pane = testing.sibling,
        .available = 5,
        .request_failure = error.RequestIdExhausted,
    };
    const handler = capture.handler();

    try std.testing.expectError(error.RequestIdExhausted, handler.execute(testing.model, testing.location));
    try std.testing.expectEqualDeep(&[_]Event{
        .{ .ensure_requests = 2 },
    }, capture.eventSlice());
}

test "PrepareTabCloseHandler rejects an unknown exact tab before port calls" {
    var testing = try TabClosePreparationTestingModel.init();
    defer testing.deinit();
    var capture: TabClosePreparationCapture = .{
        .pending_pane = testing.sibling,
        .available = 5,
    };
    const handler = capture.handler();
    const missing: TabLocationType = .{
        .workspace = testing.location.workspace,
        .tab_id = @enumFromInt(9),
    };

    try std.testing.expectError(error.UnexpectedTab, handler.execute(testing.model, missing));
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}
