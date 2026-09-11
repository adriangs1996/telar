const TabLocationType = @import("telar-core").TabLocation;
const CreatePaneLaunchAuthority = @import("CreatePaneLaunchAuthority.zig");
const CreatePanePrepareLaunch = @import("CreatePanePrepareLaunch.zig");
const AuthorityCapture = @This();

failure: ?anyerror = null,
launch_cwd: []const u8 = "/prepared",
call_count: usize = 0,
last_location: ?TabLocationType = null,

pub fn port(capture: *AuthorityCapture) CreatePaneLaunchAuthority {
    return .{ .context = capture, .prepare = prepare };
}

fn prepare(context: *anyopaque, request: CreatePanePrepareLaunch) ![]const u8 {
    const capture: *AuthorityCapture = @ptrCast(@alignCast(context));
    capture.call_count += 1;
    capture.last_location = request.location;

    if (capture.failure) |failure| {
        return failure;
    }

    return capture.launch_cwd;
}
