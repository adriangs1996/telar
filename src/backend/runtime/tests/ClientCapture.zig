const CreateTabLaunchAuthority = @import("../application/commands/CreateTabLaunchAuthority.zig");
const CreateTabPaneAttachment = @import("../application/commands/CreateTabPaneAttachment.zig");
const CreateTabPrepareLaunch = @import("../application/commands/CreateTabPrepareLaunch.zig");
const CreateTabLaunchedPane = @import("../application/commands/CreateTabLaunchedPane.zig");
const ClientCapture = @This();

attach_count: usize = 0,

pub fn authority(capture: *ClientCapture) CreateTabLaunchAuthority {
    return .{
        .context = capture,
        .prepare = prepareLaunch,
    };
}

pub fn attachment(capture: *ClientCapture) CreateTabPaneAttachment {
    return .{ .context = capture, .attach = attach };
}

fn prepareLaunch(_: *anyopaque, _: CreateTabPrepareLaunch) ![]const u8 {
    return "/prepared";
}

fn attach(context: *anyopaque, _: CreateTabLaunchedPane) !void {
    const capture: *ClientCapture = @ptrCast(@alignCast(context));
    capture.attach_count += 1;
}
