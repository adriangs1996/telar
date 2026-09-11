//! Application policy for reserving every bounded resource required by one
//! provisional workspace handoff before it produces effects.

const PaneIdType = @import("telar-core").PaneId;
const WorkspaceHandoffPreparationTestingModel = @import("WorkspaceHandoffPreparationTestingModel.zig");
const std = @import("std");
const VersionType = @import("../../model/Version.zig");
const WorkspaceHandoffPreparationCapture = @import("WorkspaceHandoffPreparationCapture.zig");

pub const Event = union(enum) {
    ensure_requests: u64,
    attachment_pending: PaneIdType,
    available_deliveries,
};

fn expectModelUnchanged(testing: *const WorkspaceHandoffPreparationTestingModel) !void {
    try std.testing.expect(testing.model.panePasteActive());
    try std.testing.expect(testing.model.reportedPaneFocus() != null);
    try std.testing.expect(testing.model.workspace.findPane(testing.root).?.attached);
    try std.testing.expect(!testing.model.workspace.findPane(testing.sibling).?.attached);
    try std.testing.expect(testing.model.workspace.findPane(testing.other_root).?.attached);
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "PrepareWorkspaceHandoffHandler accepts exact bounded capacity without effects" {
    var testing = try WorkspaceHandoffPreparationTestingModel.init();
    defer testing.deinit();
    var capture: WorkspaceHandoffPreparationCapture = .{
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
    var testing = try WorkspaceHandoffPreparationTestingModel.init();
    defer testing.deinit();
    var capture: WorkspaceHandoffPreparationCapture = .{
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
    var testing = try WorkspaceHandoffPreparationTestingModel.init();
    defer testing.deinit();
    var capture: WorkspaceHandoffPreparationCapture = .{
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
