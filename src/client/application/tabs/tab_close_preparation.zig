//! Application policy for reserving every bounded resource required by one
//! provisional tab closure before it produces effects.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../root.zig").model;
const tab_attachment_retirement = @import("tab_attachment_retirement.zig");

pub const schema = core.schema;

pub const RequestCapacity = @import("RequestCapacity.zig");

pub const DeliveryCapacity = @import("DeliveryCapacity.zig");

pub const PrepareTabCloseHandler = @import("PrepareTabCloseHandler.zig");

pub const Event = union(enum) {
    ensure_requests: u64,
    attachment_pending: schema.PaneId,
    available_deliveries,
};

const TestingModel = @import("TabClosePreparationTestingModel.zig");

const Capture = @import("TabClosePreparationCapture.zig");

test "PrepareTabCloseHandler accepts the exact required capacity without effects" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: Capture = .{
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
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: Capture = .{
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
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: Capture = .{
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
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: Capture = .{
        .pending_pane = testing.sibling,
        .available = 5,
    };
    const handler = capture.handler();
    const missing: schema.TabLocation = .{
        .workspace = testing.location.workspace,
        .tab_id = @enumFromInt(9),
    };

    try std.testing.expectError(error.UnexpectedTab, handler.execute(testing.model, missing));
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}
