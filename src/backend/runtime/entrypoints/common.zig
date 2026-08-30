//! Narrow capabilities shared by external-message entrypoints.

const core = @import("telar-core");
const history = @import("../../history/root.zig");
const pane_mod = @import("../../pane/root.zig");
const response_queue = @import("../response_queue.zig");

const schema = core.schema;

pub const ClientKey = history.model.ClientKey;
pub const Pane = pane_mod.Pane;
pub const ResponseQueue = response_queue.ResponseQueue;

pub const Scheduler = struct {
    context: *anyopaque,
    observation: *const fn (*anyopaque, *Pane) anyerror!void,
    media: *const fn (*anyopaque, *Pane) anyerror!void,
    response: *const fn (*anyopaque, *Pane) anyerror!void,
    input: *const fn (*anyopaque, *Pane) anyerror!void,
};

pub const Geometry = struct {
    context: *anyopaque,
    holds: *const fn (*anyopaque, ClientKey, schema.WorkspaceLocation) bool,
    release: *const fn (*anyopaque, ClientKey, schema.WorkspaceLocation) void,
};

pub fn queueFailure(
    responses: *ResponseQueue,
    request_id: schema.RequestId,
    code: schema.FailureCode,
    message: []const u8,
) !void {
    try responses.push(.{ .request_failed = .{
        .request_id = request_id,
        .code = code,
        .message = message,
    } });
}

pub fn queueSpawnFailure(
    responses: *ResponseQueue,
    request_id: schema.RequestId,
    spawn_error: anyerror,
) !void {
    switch (spawn_error) {
        error.PaneLimitReached => try queueFailure(
            responses,
            request_id,
            .resource_limit,
            "pane limit reached",
        ),
        error.UnsupportedEnvironment => try queueFailure(
            responses,
            request_id,
            .invalid_request,
            "custom pane environment is not supported",
        ),
        else => try queueFailure(
            responses,
            request_id,
            .spawn_failed,
            "could not start pane process",
        ),
    }
}

pub const CwdSourceScope = union(enum) {
    any,
    workspace: schema.WorkspaceLocation,
    tab: schema.TabLocation,
};

pub fn requestLaunchCwd(
    attachments: anytype,
    responses: *ResponseQueue,
    request_id: schema.RequestId,
    launch: schema.LaunchView,
    scope: CwdSourceScope,
) !?[]const u8 {
    return resolveLaunchCwd(attachments, launch, scope) catch {
        try queueFailure(
            responses,
            request_id,
            .invalid_request,
            "cwd source pane is unavailable",
        );
        return null;
    };
}

/// Resolves a launch directory from either the explicit request value or a
/// live pane attached to this client, enforcing the requested container scope.
///
/// ```zig
/// const cwd = try resolveLaunchCwd(&attachments, launch, .{ .workspace = workspace });
/// ```
pub fn resolveLaunchCwd(attachments: anytype, launch: schema.LaunchView, scope: CwdSourceScope) ![]const u8 {
    const source_id = launch.cwd_source orelse return launch.cwd;
    const attachment = attachments.find(source_id) orelse
        return error.CwdSourcePaneUnavailable;
    const pane = attachment.pane;

    if (pane.close_requested or pane.exit != null) {
        return error.CwdSourcePaneUnavailable;
    }

    switch (scope) {
        .any => {},
        .workspace => |workspace| {
            if (!@import("std").meta.eql(pane.location.workspace, workspace)) {
                return error.CwdSourceOutsideWorkspace;
            }
        },
        .tab => |location| {
            if (!@import("std").meta.eql(pane.location, location)) {
                return error.CwdSourceOutsideTab;
            }
        },
    }

    return pane.cwd.slice();
}
