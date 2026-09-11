//! Request-scoped controller for the open-pane protocol message.

const TabLocationType = @import("telar-core").TabLocation;
const workspace_module = @import("telar-core").workspace;
const tab_module = @import("telar-core").tab;
const RequestIdType = @import("telar-core").RequestId;
const OpenPaneViewType = @import("telar-core").OpenPaneView;
const pane_module = @import("telar-core").pane;
const ResponseQueue = @import("../../delivery/ResponseQueue.zig");
const StubOpenPane = @import("StubOpenPane.zig");
const OpenPaneController = @import("OpenPaneController.zig");
const std = @import("std");
const TerminalSizeType = @import("telar-core").TerminalSize;
const FailureCodeType = @import("telar-core").FailureCode;

fn testingLocation() !TabLocationType {
    return .{
        .workspace = .{ .workspace = try workspace_module(3) },
        .tab_id = try tab_module(7),
    };
}

fn testingRequest(request_id: RequestIdType) OpenPaneViewType {
    return .{
        .request_id = request_id,
        .target = .default,
        .size = .{ .cols = 120, .rows = 40 },
        .launch = .{
            .cwd = "/requested",
            .argument_count = 1,
            .encoded_arguments = "\x07\x00/bin/sh",
            .environment_mode = .inherit_runtime,
            .environment_count = 0,
            .encoded_environment = "",
        },
    };
}

test "Controller maps open-pane input to the canonical result" {
    const request_id: RequestIdType = @enumFromInt(11);
    const canonical_location = try testingLocation();
    const pane_id = try pane_module(17);
    var responses: ResponseQueue = .{};
    var stub: StubOpenPane = .{ .result = .{
        .pane = .{
            .key = .{ .id = pane_id, .generation = 9 },
            .location = canonical_location,
        },
        .created = true,
    } };
    var controller = OpenPaneController.init(&responses, stub.executor());

    try controller.openPane(testingRequest(request_id));

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expect(stub.last_command.?.target == .default);
    try std.testing.expectEqual(TerminalSizeType{ .cols = 120, .rows = 40 }, stub.last_command.?.size);
    try std.testing.expectEqualStrings("/requested", stub.last_command.?.launch.?.cwd);
    const response = responses.peek().?;
    try std.testing.expect(response.* == .pane_opened);
    try std.testing.expectEqual(request_id, response.pane_opened.request_id);
    try std.testing.expectEqual(pane_id, response.pane_opened.pane_id);
    try std.testing.expectEqualDeep(canonical_location, response.pane_opened.location);
    try std.testing.expect(response.pane_opened.created);
}

test "Controller maps every expected open-pane failure" {
    const cases = [_]struct {
        command_error: anyerror,
        failure_code: FailureCodeType,
        message: []const u8,
    }{
        .{ .command_error = error.PaneNotFound, .failure_code = .pane_not_found, .message = "pane not found" },
        .{ .command_error = error.WorkspaceNotFound, .failure_code = .workspace_not_found, .message = "workspace not found" },
        .{ .command_error = error.WorkspaceHasNoPane, .failure_code = .pane_not_found, .message = "workspace has no running pane" },
        .{ .command_error = error.InvalidOpenRequest, .failure_code = .invalid_request, .message = "default pane launch is missing" },
        .{ .command_error = error.InvalidLaunchCwd, .failure_code = .invalid_request, .message = "cwd source pane is unavailable" },
        .{ .command_error = error.WorkspaceCreateFailed, .failure_code = .resource_limit, .message = "could not create workspace" },
        .{ .command_error = error.GeometryUnavailable, .failure_code = .resource_limit, .message = "workspace geometry is leased by another client" },
        .{ .command_error = error.PaneLimitReached, .failure_code = .resource_limit, .message = "pane limit reached" },
        .{ .command_error = error.UnsupportedEnvironment, .failure_code = .invalid_request, .message = "custom pane environment is not supported" },
        .{ .command_error = error.PaneSpawnFailed, .failure_code = .spawn_failed, .message = "could not start pane process" },
        .{ .command_error = error.PaneResizeFailed, .failure_code = .internal, .message = "could not resize pane" },
    };

    for (cases, 0..) |case, index| {
        var responses: ResponseQueue = .{};
        var stub: StubOpenPane = .{ .failure = case.command_error };
        var controller = OpenPaneController.init(&responses, stub.executor());
        const request_id: RequestIdType = @enumFromInt(index + 20);

        try controller.openPane(testingRequest(request_id));

        const response = responses.peek().?;
        try std.testing.expect(response.* == .request_failed);
        try std.testing.expectEqual(request_id, response.request_failed.request_id);
        try std.testing.expectEqual(case.failure_code, response.request_failed.code);
        try std.testing.expectEqualStrings(case.message, response.request_failed.message);
    }
}

test "Controller propagates unexpected open-pane failures" {
    var responses: ResponseQueue = .{};
    var stub: StubOpenPane = .{ .failure = error.AttachmentUnavailable };
    var controller = OpenPaneController.init(&responses, stub.executor());

    try std.testing.expectError(error.AttachmentUnavailable, controller.openPane(
        testingRequest(@enumFromInt(40)),
    ));

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expect(responses.peek() == null);
}

test "Controller reports backpressure after a successful open" {
    const location = try testingLocation();
    var responses: ResponseQueue = .{};

    while (responses.len < responses.items.len) {
        try responses.push(.{ .tab_moved = .{
            .request_id = .none,
            .location = location,
            .position = 0,
        } });
    }

    var stub: StubOpenPane = .{ .result = .{
        .pane = .{
            .key = .{ .id = try pane_module(17), .generation = 9 },
            .location = location,
        },
        .created = false,
    } };
    var controller = OpenPaneController.init(&responses, stub.executor());

    try std.testing.expectError(error.ResponseQueueFull, controller.openPane(
        testingRequest(@enumFromInt(41)),
    ));

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(@as(u8, responses.items.len), responses.len);
}
