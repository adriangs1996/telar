//! Application policy for resolving one workspace-handoff destination.

const std = @import("std");
const core = @import("telar-core");

const schema = core.schema;

pub const PaneRequest = struct {
    pane_id: schema.PaneId,
    fallback_workspace: ?schema.WorkspaceId,
};

pub const Target = union(enum) {
    workspace: schema.WorkspaceId,
    pane: PaneRequest,
};

pub const Plan = struct {
    target: schema.PaneTarget,
    fallback_workspace: ?schema.WorkspaceId,
};

pub const Bookmarks = struct {
    context: *anyopaque,
    remembered_pane: *const fn (*anyopaque, schema.WorkspaceLocation) ?schema.PaneId,
};

pub const PlanWorkspaceHandoffHandler = struct {
    bookmarks: Bookmarks,

    /// Prefers a workspace's remembered pane while preserving its identity as
    /// fallback, or retains an explicit pane request exactly as supplied.
    ///
    /// ```zig
    /// const plan = handler.execute(.{ .workspace = workspace_id });
    /// ```
    pub fn execute(handler: *const PlanWorkspaceHandoffHandler, target: Target) Plan {
        return switch (target) {
            .workspace => |workspace| workspace: {
                const destination: schema.WorkspaceLocation = .{ .workspace = workspace };
                const pane_id = handler.bookmarks.remembered_pane(
                    handler.bookmarks.context,
                    destination,
                );

                break :workspace .{
                    .target = if (pane_id) |pane| .{ .pane = pane } else .{ .workspace = workspace },
                    .fallback_workspace = workspace,
                };
            },
            .pane => |pane| .{
                .target = .{ .pane = pane.pane_id },
                .fallback_workspace = pane.fallback_workspace,
            },
        };
    }
};

const Capture = struct {
    pane_id: ?schema.PaneId = null,
    calls: usize = 0,
    location: ?schema.WorkspaceLocation = null,

    fn handler(capture: *Capture) PlanWorkspaceHandoffHandler {
        return .{ .bookmarks = .{
            .context = capture,
            .remembered_pane = rememberedPane,
        } };
    }

    fn rememberedPane(context: *anyopaque, location: schema.WorkspaceLocation) ?schema.PaneId {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.location = location;

        return capture.pane_id;
    }
};

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
