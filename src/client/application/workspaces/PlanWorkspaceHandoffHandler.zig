const WorkspaceHandoffTargetingBookmarks = @import("WorkspaceHandoffTargetingBookmarks.zig");
const workspace_handoff_targeting = @import("workspace_handoff_targeting.zig");
const Plan = @import("Plan.zig");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const PlanWorkspaceHandoffHandler = @This();

bookmarks: WorkspaceHandoffTargetingBookmarks,

/// Prefers a workspace's remembered pane while preserving its identity as
/// fallback, or retains an explicit pane request exactly as supplied.
///
/// ```zig
/// const plan = handler.execute(.{ .workspace = workspace_id });
/// ```
pub fn execute(handler: *const PlanWorkspaceHandoffHandler, target: workspace_handoff_targeting.Target) Plan {
    return switch (target) {
        .workspace => |workspace| workspace: {
            const destination: WorkspaceLocationType = .{ .workspace = workspace };
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
