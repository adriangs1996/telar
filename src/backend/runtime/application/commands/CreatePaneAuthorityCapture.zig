const AuthorityCapture = @This();
const source_namespace = @import("create_pane.zig");
const LaunchAuthority = @import("CreatePaneLaunchAuthority.zig");
const PrepareLaunch = @import("CreatePanePrepareLaunch.zig");
failure: ?anyerror = null,
launch_cwd: []const u8 = "/prepared",
call_count: usize = 0,
last_location: ?source_namespace.schema.TabLocation = null,

pub fn port(capture: *AuthorityCapture) LaunchAuthority {
    return .{ .context = capture, .prepare = prepare };
}

fn prepare(context: *anyopaque, request: PrepareLaunch) ![]const u8 {
    const capture: *AuthorityCapture = @ptrCast(@alignCast(context));
    capture.call_count += 1;
    capture.last_location = request.location;

    if (capture.failure) |failure| {
        return failure;
    }

    return capture.launch_cwd;
}
