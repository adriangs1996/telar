const LauncherCapture = @This();
const source_namespace = @import("create_tab_test.zig");
const create_tab_commands = @import("../application/commands/create_tab.zig");
pane_id: source_namespace.schema.PaneId,
call_count: usize = 0,

pub fn port(capture: *LauncherCapture) create_tab_commands.PaneLauncher {
    return .{ .context = capture, .launch = launch };
}

fn launch(context: *anyopaque, _: create_tab_commands.LaunchPane) !create_tab_commands.LaunchedPane {
    const capture: *LauncherCapture = @ptrCast(@alignCast(context));
    capture.call_count += 1;
    return .{ .id = capture.pane_id };
}
