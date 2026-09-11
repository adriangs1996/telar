//! Request-scoped controller for the create-workspace protocol message.

const TabLocationType = @import("telar-core").TabLocation;
const workspace_module = @import("telar-core").workspace;
const tab_module = @import("telar-core").tab;
const RequestIdType = @import("telar-core").RequestId;
const CreateWorkspaceViewType = @import("telar-core").CreateWorkspaceView;
const pane_module = @import("telar-core").pane;
const ResponseQueue = @import("../../delivery/ResponseQueue.zig");
const StubCreateWorkspace = @import("StubCreateWorkspace.zig");
const WorkspaceCreatedType = @import("../../../workspace/WorkspaceCreated.zig");
const CreateWorkspaceController = @import("CreateWorkspaceController.zig");
const std = @import("std");
const TerminalSizeType = @import("telar-core").TerminalSize;
const EnvironmentModeType = @import("telar-core").EnvironmentMode;
const FailureCodeType = @import("telar-core").FailureCode;

fn testingLocation() !TabLocationType {
    return .{
        .workspace = .{ .workspace = try workspace_module(3) },
        .tab_id = try tab_module(7),
    };
}

fn testingRequest(request_id: RequestIdType) !CreateWorkspaceViewType {
    return .{
        .request_id = request_id,
        .name = "requested",
        .size = .{ .cols = 120, .rows = 40 },
        .launch = .{
            .cwd = "/requested",
            .cwd_source = try pane_module(5),
            .argument_count = 1,
            .encoded_arguments = "\x07\x00/bin/sh",
            .environment_mode = .replace,
            .environment_count = 1,
            .encoded_environment = "\x04\x00TERM\x05\x00xterm",
        },
    };
}

test "Controller maps create-workspace input to a canonical pane confirmation" {
    const canonical_location = try testingLocation();
    const request_id: RequestIdType = @enumFromInt(11);
    const pane_id = try pane_module(17);
    var responses: ResponseQueue = .{};
    var stub: StubCreateWorkspace = .{ .result = .{
        .created = try WorkspaceCreatedType.init(canonical_location, "canonical"),
        .root_pane_id = pane_id,
    } };
    var controller = CreateWorkspaceController.init(&responses, stub.executor());

    try controller.createWorkspace(try testingRequest(request_id));

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqualStrings("requested", stub.lastName());
    try std.testing.expectEqual(TerminalSizeType{ .cols = 120, .rows = 40 }, stub.last_size.?);
    try std.testing.expectEqualStrings("/requested", stub.lastCwd());
    try std.testing.expectEqual(try pane_module(5), stub.last_cwd_source.?);
    try std.testing.expectEqual(EnvironmentModeType.replace, stub.last_environment_mode);
    const response = responses.peek().?;
    try std.testing.expect(response.* == .pane_opened);
    try std.testing.expectEqual(request_id, response.pane_opened.request_id);
    try std.testing.expectEqual(pane_id, response.pane_opened.pane_id);
    try std.testing.expectEqualDeep(canonical_location, response.pane_opened.location);
    try std.testing.expect(response.pane_opened.created);
}

test "Controller maps every expected create-workspace failure" {
    const cases = [_]struct {
        command_error: anyerror,
        failure_code: FailureCodeType,
        message: []const u8,
    }{
        .{ .command_error = error.InvalidLaunchCwd, .failure_code = .invalid_request, .message = "cwd source pane is unavailable" },
        .{ .command_error = error.WorkspaceCreateFailed, .failure_code = .resource_limit, .message = "could not create workspace" },
        .{ .command_error = error.GeometryUnavailable, .failure_code = .resource_limit, .message = "workspace geometry is unavailable" },
        .{ .command_error = error.PaneLimitReached, .failure_code = .resource_limit, .message = "pane limit reached" },
        .{ .command_error = error.UnsupportedEnvironment, .failure_code = .invalid_request, .message = "custom pane environment is not supported" },
        .{ .command_error = error.PaneSpawnFailed, .failure_code = .spawn_failed, .message = "could not start pane process" },
    };

    for (cases, 0..) |case, index| {
        var responses: ResponseQueue = .{};
        var stub: StubCreateWorkspace = .{ .failure = case.command_error };
        var controller = CreateWorkspaceController.init(&responses, stub.executor());
        const request_id: RequestIdType = @enumFromInt(index + 20);

        try controller.createWorkspace(try testingRequest(request_id));

        const response = responses.peek().?;
        try std.testing.expect(response.* == .request_failed);
        try std.testing.expectEqual(request_id, response.request_failed.request_id);
        try std.testing.expectEqual(case.failure_code, response.request_failed.code);
        try std.testing.expectEqualStrings(case.message, response.request_failed.message);
    }
}

test "Controller propagates unexpected create-workspace failures" {
    var responses: ResponseQueue = .{};
    var stub: StubCreateWorkspace = .{ .failure = error.AttachmentUnavailable };
    var controller = CreateWorkspaceController.init(&responses, stub.executor());

    try std.testing.expectError(error.AttachmentUnavailable, controller.createWorkspace(
        try testingRequest(@enumFromInt(30)),
    ));

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expect(responses.peek() == null);
}
