const AuthorityCapture = @This();
const source_namespace = @import("create_workspace.zig");
const LaunchAuthority = @import("CreateWorkspaceLaunchAuthority.zig");
const PrepareLaunch = @import("CreateWorkspacePrepareLaunch.zig");
const std = @import("std");
failure: ?anyerror = null,
launch_cwd: []const u8 = "/prepared",
call_count: usize = 0,
last_requested_cwd: [source_namespace.schema.max_cwd_bytes]u8 = undefined,
last_requested_cwd_len: usize = 0,

pub fn port(capture: *AuthorityCapture) LaunchAuthority {
    return .{ .context = capture, .prepare = prepare };
}

fn prepare(context: *anyopaque, request: PrepareLaunch) ![]const u8 {
    const capture: *AuthorityCapture = @ptrCast(@alignCast(context));
    std.debug.assert(request.launch.cwd.len <= capture.last_requested_cwd.len);

    capture.call_count += 1;
    capture.last_requested_cwd_len = request.launch.cwd.len;
    @memcpy(capture.last_requested_cwd[0..request.launch.cwd.len], request.launch.cwd);

    if (capture.failure) |failure| {
        return failure;
    }

    return capture.launch_cwd;
}

pub fn requestedCwd(capture: *const AuthorityCapture) []const u8 {
    return capture.last_requested_cwd[0..capture.last_requested_cwd_len];
}
