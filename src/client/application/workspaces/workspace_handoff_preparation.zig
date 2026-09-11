//! Application policy for reserving every bounded resource required by one
//! provisional workspace handoff before it produces effects.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../root.zig").model;
const tab_attachment_retirement = @import("../tabs/root.zig").tab_attachment_retirement;

pub const schema = core.schema;

pub const RequestCapacity = @import("RequestCapacity.zig");

pub const DeliveryCapacity = @import("DeliveryCapacity.zig");

pub const PrepareWorkspaceHandoffHandler = @import("PrepareWorkspaceHandoffHandler.zig");

pub const Event = union(enum) {
    ensure_requests: u64,
    attachment_pending: schema.PaneId,
    available_deliveries,
};

const TestingModel = @import("WorkspaceHandoffPreparationTestingModel.zig");

const Capture = @import("WorkspaceHandoffPreparationCapture.zig");

fn expectModelUnchanged(testing: *const TestingModel) !void {
    try std.testing.expect(testing.model.panePasteActive());
    try std.testing.expect(testing.model.reportedPaneFocus() != null);
    try std.testing.expect(testing.model.workspace.findPane(testing.root).?.attached);
    try std.testing.expect(!testing.model.workspace.findPane(testing.sibling).?.attached);
    try std.testing.expect(testing.model.workspace.findPane(testing.other_root).?.attached);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "PrepareWorkspaceHandoffHandler accepts exact bounded capacity without effects" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: Capture = .{
        .model = testing.model,
        .pending_pane = testing.sibling,
        .available = 6,
    };
    const handler = capture.handler();

    try handler.execute();

    try std.testing.expectEqualDeep(&[_]Event{
        .{ .ensure_requests = 2 },
        .{ .attachment_pending = testing.root },
        .{ .attachment_pending = testing.sibling },
        .{ .attachment_pending = testing.other_root },
        .available_deliveries,
    }, capture.eventSlice());
    try std.testing.expect(capture.queries_observed_unchanged);
    try expectModelUnchanged(&testing);
}

test "PrepareWorkspaceHandoffHandler rejects delivery exhaustion without effects" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: Capture = .{
        .model = testing.model,
        .pending_pane = testing.sibling,
        .available = 5,
    };
    const handler = capture.handler();

    try std.testing.expectError(error.ClientOutboxFull, handler.execute());

    try std.testing.expectEqualDeep(&[_]Event{
        .{ .ensure_requests = 2 },
        .{ .attachment_pending = testing.root },
        .{ .attachment_pending = testing.sibling },
        .{ .attachment_pending = testing.other_root },
        .available_deliveries,
    }, capture.eventSlice());
    try std.testing.expect(capture.queries_observed_unchanged);
    try expectModelUnchanged(&testing);
}

test "PrepareWorkspaceHandoffHandler rejects request exhaustion before delivery queries" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: Capture = .{
        .model = testing.model,
        .pending_pane = testing.sibling,
        .available = 6,
        .request_failure = error.RequestIdExhausted,
    };
    const handler = capture.handler();

    try std.testing.expectError(error.RequestIdExhausted, handler.execute());

    try std.testing.expectEqualDeep(&[_]Event{
        .{ .ensure_requests = 2 },
    }, capture.eventSlice());
    try expectModelUnchanged(&testing);
}
