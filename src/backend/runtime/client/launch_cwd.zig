//! Launch-directory authority shared by client request entrypoints.

const core = @import("telar-core");
const std = @import("std");
const RuntimeModel = @import("../RuntimeModel.zig");
const Session = @import("Session.zig");

pub const CwdSourceScope = union(enum) {
    any,
    workspace: core.WorkspaceLocation,
    tab: core.TabLocation,
};

/// Resolves a launch directory from either the explicit request value or a
/// live pane attached to this client, enforcing the requested container scope.
///
/// ```zig
/// const cwd = try resolveLaunchCwd(model, session, launch, .{ .workspace = workspace });
/// ```
pub fn resolveLaunchCwd(model: *RuntimeModel, session: *const Session, launch: core.LaunchView, scope: CwdSourceScope) ![]const u8 {
    const source_id = launch.cwd_source orelse return launch.cwd;
    const attachment = model.attachments.find(session.slot, source_id) orelse
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

/// Creates a confirmed absolute launch directory and its parents. An
/// existing directory is accepted; anything else at that path is refused so
/// a workspace never launches inside a file.
///
/// ```zig
/// try createLaunchDirectory(io, "/home/me/sandbox/new-project");
/// ```
pub fn createLaunchDirectory(io: std.Io, cwd: []const u8) !void {
    if (cwd.len == 0 or cwd[0] != '/') {
        return error.RelativeLaunchCwd;
    }

    const status = try std.Io.Dir.cwd().createDirPathStatus(io, cwd, .default_dir);
    if (status == .created) {
        return;
    }

    const stat = try std.Io.Dir.cwd().statFile(io, cwd, .{});
    if (stat.kind != .directory) {
        return error.LaunchCwdNotDirectory;
    }
}
