const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const max_cwd_bytes_module = @import("telar-core").max_cwd_bytes;
const PaneIdType = @import("telar-core").PaneId;
const CreateTabLaunchAuthority = @import("CreateTabLaunchAuthority.zig");
const CreateTabPaneAttachment = @import("CreateTabPaneAttachment.zig");
const CreateTabPrepareLaunch = @import("CreateTabPrepareLaunch.zig");
const std = @import("std");
const CreateTabLaunchedPane = @import("CreateTabLaunchedPane.zig");
const ClientCapture = @This();

prepare_failure: ?anyerror = null,
attach_failure: ?anyerror = null,
launch_cwd: []const u8 = "/prepared",
prepare_count: usize = 0,
attach_count: usize = 0,
last_workspace: ?WorkspaceLocationType = null,
last_requested_cwd: [max_cwd_bytes_module]u8 = undefined,
last_requested_cwd_len: usize = 0,
last_pane_id: PaneIdType = .invalid,
event_count: ?*const usize = null,
event_observed_before_attach: bool = false,

pub fn authority(capture: *ClientCapture) CreateTabLaunchAuthority {
    return .{
        .context = capture,
        .prepare = prepareLaunch,
    };
}

pub fn attachment(capture: *ClientCapture) CreateTabPaneAttachment {
    return .{ .context = capture, .attach = attach };
}

fn prepareLaunch(context: *anyopaque, request: CreateTabPrepareLaunch) ![]const u8 {
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

fn attach(context: *anyopaque, pane: CreateTabLaunchedPane) !void {
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
