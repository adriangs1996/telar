//! Launch-directory authority shared by client request entrypoints.

const core = @import("telar-core");

const schema = core.schema;

pub const CwdSourceScope = union(enum) {
    any,
    workspace: schema.WorkspaceLocation,
    tab: schema.TabLocation,
};

/// Resolves a launch directory from either the explicit request value or a
/// live pane attached to this client, enforcing the requested container scope.
///
/// ```zig
/// const cwd = try resolveLaunchCwd(&attachments, launch, .{ .workspace = workspace });
/// ```
pub fn resolveLaunchCwd(attachments: anytype, launch: schema.LaunchView, scope: CwdSourceScope) ![]const u8 {
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
            if (!@import("std").meta.eql(pane.location.workspace, workspace)) {
                return error.CwdSourceOutsideWorkspace;
            }
        },
        .tab => |location| {
            if (!@import("std").meta.eql(pane.location, location)) {
                return error.CwdSourceOutsideTab;
            }
        },
    }

    return pane.cwd.slice();
}
