const PaneIdType = @import("telar-core").PaneId;
const TabLocationType = @import("telar-core").TabLocation;
const TerminalSizeType = @import("telar-core").TerminalSize;
const max_cwd_bytes_module = @import("telar-core").max_cwd_bytes;
const CreateTabPaneLauncher = @import("CreateTabPaneLauncher.zig");
const CreateTabLaunchPane = @import("CreateTabLaunchPane.zig");
const CreateTabLaunchedPane = @import("CreateTabLaunchedPane.zig");
const std = @import("std");
const LauncherCapture = @This();

failure: ?anyerror = null,
pane_id: PaneIdType = .invalid,
call_count: usize = 0,
last_location: ?TabLocationType = null,
last_size: ?TerminalSizeType = null,
last_launch_cwd: [max_cwd_bytes_module]u8 = undefined,
last_launch_cwd_len: usize = 0,
last_workspace_path: [max_cwd_bytes_module]u8 = undefined,
last_workspace_path_len: usize = 0,
last_argument_count: u16 = 0,

pub fn port(capture: *LauncherCapture) CreateTabPaneLauncher {
    return .{ .context = capture, .launch = launch };
}

fn launch(context: *anyopaque, request: CreateTabLaunchPane) !CreateTabLaunchedPane {
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
    capture.last_argument_count = request.launch.argument_count;

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
