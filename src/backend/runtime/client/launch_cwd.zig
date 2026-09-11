//! Launch-directory authority shared by client request entrypoints.

const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const TabLocationType = @import("telar-core").TabLocation;
const LaunchViewType = @import("telar-core").LaunchView;
const std = @import("std");

pub const CwdSourceScope = union(enum) {
    any,
    workspace: WorkspaceLocationType,
    tab: TabLocationType,
};

/// Resolves a launch directory from either the explicit request value or a
/// live pane attached to this client, enforcing the requested container scope.
///
/// ```zig
/// const cwd = try resolveLaunchCwd(&attachments, launch, .{ .workspace = workspace });
/// ```
pub fn resolveLaunchCwd(attachments: anytype, launch: LaunchViewType, scope: CwdSourceScope) ![]const u8 {
    const source_id = launch.cwd_source orelse return launch.cwd;
    const attachment = attachments.find(source_id) orelse
        return error.CwdSourcePaneUnavailable;
    const pane = attachment.pane;

    if (pane.close_requested or pane.exit != null) {
        return error.CwdSourcePaneUnavailable;
    }

    switch (scope) {
        .any => {},
        .workspace => |workspace| {
            if (!std.meta.eql(pane.location.workspace, workspace)) {
                return error.CwdSourceOutsideWorkspace;
            }
        },
        .tab => |location| {
            if (!std.meta.eql(pane.location, location)) {
                return error.CwdSourceOutsideTab;
            }
        },
    }

    return pane.cwd.slice();
}
