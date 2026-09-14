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

test "createLaunchDirectory creates missing parents and refuses files and relative paths" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try temp.dir.realPath(io, &buffer)];
    var nested_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const nested = try std.fmt.bufPrint(&nested_buffer, "{s}/one/two", .{root});

    try createLaunchDirectory(io, nested);
    try createLaunchDirectory(io, nested);
    try std.testing.expectEqual(std.Io.File.Kind.directory, (try temp.dir.statFile(io, "one/two", .{})).kind);

    const file = try temp.dir.createFile(io, "one/plain", .{});
    file.close(io);
    var file_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const plain = try std.fmt.bufPrint(&file_buffer, "{s}/one/plain", .{root});
    try std.testing.expectError(error.NotDir, createLaunchDirectory(io, plain));
    try std.testing.expectError(error.RelativeLaunchCwd, createLaunchDirectory(io, "relative/path"));
}
