const ClientCapture = @This();
const create_tab_commands = @import("../application/commands/create_tab.zig");
attach_count: usize = 0,

pub fn authority(capture: *ClientCapture) create_tab_commands.LaunchAuthority {
    return .{
        .context = capture,
        .prepare = prepareLaunch,
    };
}

pub fn attachment(capture: *ClientCapture) create_tab_commands.PaneAttachment {
    return .{ .context = capture, .attach = attach };
}

fn prepareLaunch(_: *anyopaque, _: create_tab_commands.PrepareLaunch) ![]const u8 {
    return "/prepared";
}

fn attach(context: *anyopaque, _: create_tab_commands.LaunchedPane) !void {
    const capture: *ClientCapture = @ptrCast(@alignCast(context));
    capture.attach_count += 1;
}
