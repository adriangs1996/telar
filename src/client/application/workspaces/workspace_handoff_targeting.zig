//! Application policy for resolving one workspace-handoff destination.

const WorkspaceIdType = @import("telar-core").WorkspaceId;
const PaneRequest = @import("PaneRequest.zig");
const WorkspaceHandoffTargetingCapture = @import("WorkspaceHandoffTargetingCapture.zig");
const std = @import("std");
const Plan = @import("Plan.zig");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const PaneIdType = @import("telar-core").PaneId;

pub const Target = union(enum) {
    workspace: WorkspaceIdType,
    pane: PaneRequest,
};

test "PlanWorkspaceHandoffHandler targets a workspace without a bookmark" {
    var capture: WorkspaceHandoffTargetingCapture = .{};
    const handler = capture.handler();
    const workspace: WorkspaceIdType = @enumFromInt(3);

    const plan = handler.execute(.{ .workspace = workspace });

    try std.testing.expectEqualDeep(Plan{
        .target = .{ .workspace = workspace },
        .fallback_workspace = workspace,
    }, plan);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualDeep(WorkspaceLocationType{ .workspace = workspace }, capture.location.?);
}

test "PlanWorkspaceHandoffHandler prefers the remembered pane with workspace fallback" {
    const pane_id: PaneIdType = @enumFromInt(7);
    var capture: WorkspaceHandoffTargetingCapture = .{ .pane_id = pane_id };
    const handler = capture.handler();
    const workspace: WorkspaceIdType = @enumFromInt(3);

    const plan = handler.execute(.{ .workspace = workspace });

    try std.testing.expectEqualDeep(Plan{
        .target = .{ .pane = pane_id },
        .fallback_workspace = workspace,
    }, plan);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}

test "PlanWorkspaceHandoffHandler preserves explicit pane requests without bookmark lookup" {
    const pane_id: PaneIdType = @enumFromInt(7);
    inline for (.{
        @as(?WorkspaceIdType, null),
        @as(?WorkspaceIdType, @enumFromInt(3)),
    }) |fallback| {
        var capture: WorkspaceHandoffTargetingCapture = .{ .pane_id = @enumFromInt(9) };
        const handler = capture.handler();

        const plan = handler.execute(.{ .pane = .{
            .pane_id = pane_id,
            .fallback_workspace = fallback,
        } });

        try std.testing.expectEqualDeep(Plan{
            .target = .{ .pane = pane_id },
            .fallback_workspace = fallback,
        }, plan);
        try std.testing.expectEqual(@as(usize, 0), capture.calls);
    }
}
