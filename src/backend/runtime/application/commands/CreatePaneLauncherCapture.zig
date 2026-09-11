const PaneLaunchedType = @import("../../../pane/PaneLaunched.zig");
const CreatePaneLaunchPane = @import("CreatePaneLaunchPane.zig");
const CreatePaneLauncher = @import("CreatePaneLauncher.zig");
const LauncherCapture = @This();

failure: ?anyerror = null,
result: PaneLaunchedType,
call_count: usize = 0,
last_request: ?CreatePaneLaunchPane = null,

pub fn port(capture: *LauncherCapture) CreatePaneLauncher {
    return .{ .context = capture, .launch = launch };
}

fn launch(context: *anyopaque, request: CreatePaneLaunchPane) !PaneLaunchedType {
    const capture: *LauncherCapture = @ptrCast(@alignCast(context));
    capture.call_count += 1;
    capture.last_request = request;

    if (capture.failure) |failure| {
        return failure;
    }

    return capture.result;
}
