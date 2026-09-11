const AuthorityCapture = @This();
const LaunchAuthority = @import("OpenPaneLaunchAuthority.zig");
const PrepareLaunch = @import("OpenPanePrepareLaunch.zig");
failure: ?anyerror = null,
cwd: []const u8 = "/work/project",
count: usize = 0,

pub fn port(capture: *AuthorityCapture) LaunchAuthority {
    return .{ .context = capture, .prepare = prepare };
}

fn prepare(context: *anyopaque, _: PrepareLaunch) ![]const u8 {
    const capture: *AuthorityCapture = @ptrCast(@alignCast(context));
    capture.count += 1;

    if (capture.failure) |failure| {
        return failure;
    }

    return capture.cwd;
}
