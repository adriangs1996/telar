const OpenPaneLaunchAuthority = @import("OpenPaneLaunchAuthority.zig");
const OpenPanePrepareLaunch = @import("OpenPanePrepareLaunch.zig");
const AuthorityCapture = @This();

failure: ?anyerror = null,
cwd: []const u8 = "/work/project",
count: usize = 0,

pub fn port(capture: *AuthorityCapture) OpenPaneLaunchAuthority {
    return .{ .context = capture, .prepare = prepare };
}

fn prepare(context: *anyopaque, _: OpenPanePrepareLaunch) ![]const u8 {
    const capture: *AuthorityCapture = @ptrCast(@alignCast(context));
    capture.count += 1;

    if (capture.failure) |failure| {
        return failure;
    }

    return capture.cwd;
}
