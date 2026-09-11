const LauncherCapture = @This();
const pane_mod = @import("../../../pane/root.zig");
const LaunchPane = @import("CreatePaneLaunchPane.zig");
const PaneLauncher = @import("CreatePanePaneLauncher.zig");
failure: ?anyerror = null,
result: pane_mod.PaneLaunched,
call_count: usize = 0,
last_request: ?LaunchPane = null,

pub fn port(capture: *LauncherCapture) PaneLauncher {
    return .{ .context = capture, .launch = launch };
}

fn launch(context: *anyopaque, request: LaunchPane) !pane_mod.PaneLaunched {
    const capture: *LauncherCapture = @ptrCast(@alignCast(context));
    capture.call_count += 1;
    capture.last_request = request;

    if (capture.failure) |failure| {
        return failure;
    }

    return capture.result;
}
