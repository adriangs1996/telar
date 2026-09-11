//! Application admission policy for starting one workspace handoff.

const std = @import("std");
const client_model = @import("../../root.zig").model;

pub const Authority = enum {
    requested_departure,
    canonical_follow,
};

pub const Gate = @import("Gate.zig");

pub const AdmitWorkspaceHandoffHandler = @import("AdmitWorkspaceHandoffHandler.zig");

const GateCapture = @import("GateCapture.zig");

test "requested workspace departure requires an idle request lifecycle" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: GateCapture = .{ .blocked = true };
    const handler: AdmitWorkspaceHandoffHandler = .{
        .model = &model,
        .gate = capture.gate(),
    };

    try std.testing.expectError(
        error.WorkspaceSwitchWhileRequestPending,
        handler.execute(.requested_departure),
    );
    try std.testing.expectEqual(@as(usize, 1), capture.calls);

    capture.blocked = false;
    try handler.execute(.requested_departure);
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
}

test "canonical workspace follow ignores stale requests only from an empty projection" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: GateCapture = .{ .blocked = true };
    const handler: AdmitWorkspaceHandoffHandler = .{
        .model = &model,
        .gate = capture.gate(),
    };

    try handler.execute(.canonical_follow);
    try std.testing.expectEqual(@as(usize, 0), capture.calls);

    try model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    }, .size = .{ .cols = 20, .rows = 5 } });

    try std.testing.expectError(
        error.WorkspaceStillActive,
        handler.execute(.canonical_follow),
    );
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
}
