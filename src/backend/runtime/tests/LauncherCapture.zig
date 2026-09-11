const PaneIdType = @import("telar-core").PaneId;
const CreateTabPaneLauncher = @import("../application/commands/CreateTabPaneLauncher.zig");
const CreateTabLaunchPane = @import("../application/commands/CreateTabLaunchPane.zig");
const CreateTabLaunchedPane = @import("../application/commands/CreateTabLaunchedPane.zig");
const LauncherCapture = @This();

pane_id: PaneIdType,
call_count: usize = 0,

pub fn port(capture: *LauncherCapture) CreateTabPaneLauncher {
    return .{ .context = capture, .launch = launch };
}

fn launch(context: *anyopaque, _: CreateTabLaunchPane) !CreateTabLaunchedPane {
    const capture: *LauncherCapture = @ptrCast(@alignCast(context));
    capture.call_count += 1;
    return .{ .id = capture.pane_id };
}
