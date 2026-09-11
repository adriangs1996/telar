//! Application policy for resolving one workspace-handoff destination.

const std = @import("std");
const core = @import("telar-core");

pub const schema = core.schema;

pub const PaneRequest = @import("PaneRequest.zig");

pub const Target = union(enum) {
    workspace: schema.WorkspaceId,
    pane: PaneRequest,
};

pub const Plan = @import("Plan.zig");

pub const Bookmarks = @import("WorkspaceHandoffTargetingBookmarks.zig");

pub const PlanWorkspaceHandoffHandler = @import("PlanWorkspaceHandoffHandler.zig");

const Capture = @import("WorkspaceHandoffTargetingCapture.zig");

test "PlanWorkspaceHandoffHandler targets a workspace without a bookmark" {
    var capture: Capture = .{};
    const handler = capture.handler();
    const workspace: schema.WorkspaceId = @enumFromInt(3);

    const plan = handler.execute(.{ .workspace = workspace });

    try std.testing.expectEqualDeep(Plan{
        .target = .{ .workspace = workspace },
        .fallback_workspace = workspace,
    }, plan);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualDeep(schema.WorkspaceLocation{ .workspace = workspace }, capture.location.?);
}

test "PlanWorkspaceHandoffHandler prefers the remembered pane with workspace fallback" {
    const pane_id: schema.PaneId = @enumFromInt(7);
    var capture: Capture = .{ .pane_id = pane_id };
    const handler = capture.handler();
    const workspace: schema.WorkspaceId = @enumFromInt(3);

    const plan = handler.execute(.{ .workspace = workspace });

    try std.testing.expectEqualDeep(Plan{
        .target = .{ .pane = pane_id },
        .fallback_workspace = workspace,
    }, plan);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}

test "PlanWorkspaceHandoffHandler preserves explicit pane requests without bookmark lookup" {
    const pane_id: schema.PaneId = @enumFromInt(7);
    inline for (.{
        @as(?schema.WorkspaceId, null),
        @as(?schema.WorkspaceId, @enumFromInt(3)),
    }) |fallback| {
        var capture: Capture = .{ .pane_id = @enumFromInt(9) };
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
