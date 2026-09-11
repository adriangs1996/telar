const PlanWorkspaceHandoffHandler = @This();
const Bookmarks = @import("WorkspaceHandoffTargetingBookmarks.zig");
const source_namespace = @import("workspace_handoff_targeting.zig");
const Plan = @import("Plan.zig");
bookmarks: Bookmarks,

/// Prefers a workspace's remembered pane while preserving its identity as
/// fallback, or retains an explicit pane request exactly as supplied.
///
/// ```zig
/// const plan = handler.execute(.{ .workspace = workspace_id });
/// ```
pub fn execute(handler: *const PlanWorkspaceHandoffHandler, target: source_namespace.Target) Plan {
    return switch (target) {
        .workspace => |workspace| workspace: {
            const destination: source_namespace.schema.WorkspaceLocation = .{ .workspace = workspace };
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
