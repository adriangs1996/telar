const LauncherCapture = @This();
const source_namespace = @import("create_workspace.zig");
const PaneLauncher = @import("CreateWorkspacePaneLauncher.zig");
const LaunchPane = @import("CreateWorkspaceLaunchPane.zig");
const LaunchedPane = @import("CreateWorkspaceLaunchedPane.zig");
const std = @import("std");
failure: ?anyerror = null,
pane_id: source_namespace.schema.PaneId,
call_count: usize = 0,
last_location: ?source_namespace.schema.TabLocation = null,
last_size: ?source_namespace.schema.TerminalSize = null,
last_launch_cwd: [source_namespace.schema.max_cwd_bytes]u8 = undefined,
last_launch_cwd_len: usize = 0,
last_workspace_path: [source_namespace.schema.max_cwd_bytes]u8 = undefined,
last_workspace_path_len: usize = 0,

pub fn port(capture: *LauncherCapture) PaneLauncher {
    return .{ .context = capture, .launch = launch };
}

fn launch(context: *anyopaque, request: LaunchPane) !LaunchedPane {
    const capture: *LauncherCapture = @ptrCast(@alignCast(context));
    std.debug.assert(request.launch_cwd.len <= capture.last_launch_cwd.len);
    std.debug.assert(request.workspace_path.len <= capture.last_workspace_path.len);

    capture.call_count += 1;
    capture.last_location = request.location;
    capture.last_size = request.size;
    capture.last_launch_cwd_len = request.launch_cwd.len;
    @memcpy(capture.last_launch_cwd[0..request.launch_cwd.len], request.launch_cwd);
    capture.last_workspace_path_len = request.workspace_path.len;
    @memcpy(capture.last_workspace_path[0..request.workspace_path.len], request.workspace_path);

    if (capture.failure) |failure| {
        return failure;
    }

    return .{ .id = capture.pane_id };
}

pub fn launchCwd(capture: *const LauncherCapture) []const u8 {
    return capture.last_launch_cwd[0..capture.last_launch_cwd_len];
}

pub fn workspacePath(capture: *const LauncherCapture) []const u8 {
    return capture.last_workspace_path[0..capture.last_workspace_path_len];
}
