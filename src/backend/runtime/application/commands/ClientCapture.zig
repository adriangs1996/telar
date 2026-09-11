const ClientCapture = @This();
const source_namespace = @import("create_tab.zig");
const LaunchAuthority = @import("CreateTabLaunchAuthority.zig");
const PaneAttachment = @import("CreateTabPaneAttachment.zig");
const PrepareLaunch = @import("CreateTabPrepareLaunch.zig");
const std = @import("std");
const LaunchedPane = @import("CreateTabLaunchedPane.zig");
prepare_failure: ?anyerror = null,
attach_failure: ?anyerror = null,
launch_cwd: []const u8 = "/prepared",
prepare_count: usize = 0,
attach_count: usize = 0,
last_workspace: ?source_namespace.schema.WorkspaceLocation = null,
last_requested_cwd: [source_namespace.schema.max_cwd_bytes]u8 = undefined,
last_requested_cwd_len: usize = 0,
last_pane_id: source_namespace.schema.PaneId = .invalid,
event_count: ?*const usize = null,
event_observed_before_attach: bool = false,

pub fn authority(capture: *ClientCapture) LaunchAuthority {
    return .{
        .context = capture,
        .prepare = prepareLaunch,
    };
}

pub fn attachment(capture: *ClientCapture) PaneAttachment {
    return .{ .context = capture, .attach = attach };
}

fn prepareLaunch(context: *anyopaque, request: PrepareLaunch) ![]const u8 {
    const capture: *ClientCapture = @ptrCast(@alignCast(context));
    std.debug.assert(request.launch.cwd.len <= capture.last_requested_cwd.len);

    capture.prepare_count += 1;
    capture.last_workspace = request.workspace;
    capture.last_requested_cwd_len = request.launch.cwd.len;
    @memcpy(capture.last_requested_cwd[0..request.launch.cwd.len], request.launch.cwd);

    if (capture.prepare_failure) |failure| {
        return failure;
    }

    return capture.launch_cwd;
}

fn attach(context: *anyopaque, pane: LaunchedPane) !void {
    const capture: *ClientCapture = @ptrCast(@alignCast(context));

    capture.attach_count += 1;
    capture.last_pane_id = pane.id;

    if (capture.event_count) |count| {
        capture.event_observed_before_attach = count.* == 1;
    }

    if (capture.attach_failure) |failure| {
        return failure;
    }
}

pub fn requestedCwd(capture: *const ClientCapture) []const u8 {
    return capture.last_requested_cwd[0..capture.last_requested_cwd_len];
}
