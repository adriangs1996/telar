//! Request-scoped controller for the create-pane protocol message.

const TabLocationType = @import("telar-core").TabLocation;
const workspace_module = @import("telar-core").workspace;
const tab_module = @import("telar-core").tab;
const RequestIdType = @import("telar-core").RequestId;
const CreatePaneViewType = @import("telar-core").CreatePaneView;
const pane_module = @import("telar-core").pane;
const ResponseQueue = @import("../../delivery/ResponseQueue.zig");
const StubCreatePane = @import("StubCreatePane.zig");
const CreatePaneController = @import("CreatePaneController.zig");
const std = @import("std");
const TerminalSizeType = @import("telar-core").TerminalSize;
const FailureCodeType = @import("telar-core").FailureCode;

fn testingLocation() !TabLocationType {
    return .{
        .workspace = .{ .workspace = try workspace_module(3) },
        .tab_id = try tab_module(7),
    };
}

fn testingRequest(request_id: RequestIdType) !CreatePaneViewType {
    return .{
        .request_id = request_id,
        .location = try testingLocation(),
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

test "Controller maps create-pane input to the canonical launch result" {
    const request_id: RequestIdType = @enumFromInt(11);
    const canonical_location: TabLocationType = .{
        .workspace = .{ .workspace = try workspace_module(4) },
        .tab_id = try tab_module(8),
    };
    const pane_id = try pane_module(17);
    var responses: ResponseQueue = .{};
    var stub: StubCreatePane = .{ .result = .{
        .key = .{ .id = pane_id, .generation = 9 },
        .location = canonical_location,
    } };
    var controller = CreatePaneController.init(&responses, stub.executor());

    try controller.createPane(try testingRequest(request_id));

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqualDeep(try testingLocation(), stub.last_command.?.location);
    try std.testing.expectEqual(TerminalSizeType{ .cols = 120, .rows = 40 }, stub.last_command.?.size);
    try std.testing.expectEqualStrings("/requested", stub.last_command.?.launch.cwd);
    const response = responses.peek().?;
    try std.testing.expect(response.* == .pane_opened);
    try std.testing.expectEqual(request_id, response.pane_opened.request_id);
    try std.testing.expectEqual(pane_id, response.pane_opened.pane_id);
    try std.testing.expectEqualDeep(canonical_location, response.pane_opened.location);
    try std.testing.expect(response.pane_opened.created);
}

test "Controller maps every expected create-pane failure" {
    const cases = [_]struct {
        command_error: anyerror,
        failure_code: FailureCodeType,
        message: []const u8,
    }{
        .{ .command_error = error.TabNotFound, .failure_code = .pane_not_found, .message = "tab not found" },
        .{ .command_error = error.GeometryUnavailable, .failure_code = .resource_limit, .message = "workspace geometry is leased by another client" },
        .{ .command_error = error.InvalidLaunchCwd, .failure_code = .invalid_request, .message = "cwd source pane is unavailable" },
        .{ .command_error = error.PaneLimitReached, .failure_code = .resource_limit, .message = "pane limit reached" },
        .{ .command_error = error.UnsupportedEnvironment, .failure_code = .invalid_request, .message = "custom pane environment is not supported" },
        .{ .command_error = error.PaneSpawnFailed, .failure_code = .spawn_failed, .message = "could not start pane process" },
    };

    for (cases, 0..) |case, index| {
        var responses: ResponseQueue = .{};
        var stub: StubCreatePane = .{ .failure = case.command_error };
        var controller = CreatePaneController.init(&responses, stub.executor());
        const request_id: RequestIdType = @enumFromInt(index + 20);

        try controller.createPane(try testingRequest(request_id));

        const response = responses.peek().?;
        try std.testing.expect(response.* == .request_failed);
        try std.testing.expectEqual(request_id, response.request_failed.request_id);
        try std.testing.expectEqual(case.failure_code, response.request_failed.code);
        try std.testing.expectEqualStrings(case.message, response.request_failed.message);
    }
}

test "Controller propagates post-launch attachment failures" {
    var responses: ResponseQueue = .{};
    var stub: StubCreatePane = .{ .failure = error.AttachmentUnavailable };
    var controller = CreatePaneController.init(&responses, stub.executor());

    try std.testing.expectError(error.AttachmentUnavailable, controller.createPane(
        try testingRequest(@enumFromInt(30)),
    ));

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expect(responses.peek() == null);
}
