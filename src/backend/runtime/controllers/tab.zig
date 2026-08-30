//! Request-scoped controller for tab protocol messages.

const std = @import("std");
const core = @import("telar-core");
const tab_commands = @import("../commands/tab.zig");
const response_queue = @import("../response_queue.zig");

const schema = core.schema;
const PendingTabRenamed = response_queue.PendingTabRenamed;
const ResponseQueue = response_queue.ResponseQueue;

pub const Controller = struct {
    responses: *ResponseQueue,
    rename_tab: tab_commands.RenameTabExecutor,

    /// Creates one controller for the lifetime of a runtime request.
    ///
    /// ```zig
    /// var controller = Controller.init(&responses, handler.executor());
    /// ```
    pub fn init(responses: *ResponseQueue, rename_tab: tab_commands.RenameTabExecutor) Controller {
        return .{ .responses = responses, .rename_tab = rename_tab };
    }

    /// Translates a wire rename request into an application command and maps
    /// its result or domain error back into one client response.
    ///
    /// ```zig
    /// try controller.renameTab(request);
    /// ```
    pub fn renameTab(controller: *Controller, request: schema.RenameTab) !void {
        const renamed = controller.rename_tab.execute(.{
            .location = request.location,
            .label = request.label,
        }) catch |err| {
            switch (err) {
                error.TabNotFound => try controller.queueFailure(request.request_id, .{
                    .code = .tab_not_found,
                    .message = "tab not found",
                }),
                error.InvalidTabLabel => try controller.queueFailure(request.request_id, .{
                    .code = .invalid_request,
                    .message = "invalid tab label",
                }),
                else => return err,
            }

            return;
        };

        const label = renamed.labelSlice();
        var pending: PendingTabRenamed = .{
            .request_id = request.request_id,
            .location = renamed.location,
            .label = undefined,
            .label_len = @intCast(label.len),
        };
        @memcpy(pending.label[0..pending.label_len], label);
        try controller.responses.push(.{ .tab_renamed = pending });
    }

    fn queueFailure(controller: *Controller, request_id: schema.RequestId, failure: Failure) !void {
        try controller.responses.push(.{ .request_failed = .{
            .request_id = request_id,
            .code = failure.code,
            .message = failure.message,
        } });
    }
};

const Failure = struct {
    code: schema.FailureCode,
    message: []const u8,
};

const StubRenameTab = struct {
    result: ?tab_commands.RenameTabResult = null,
    failure: ?anyerror = null,
    call_count: usize = 0,
    last_location: ?schema.TabLocation = null,
    last_label: [schema.max_tab_label_bytes]u8 = undefined,
    last_label_len: u8 = 0,

    fn executor(stub: *StubRenameTab) tab_commands.RenameTabExecutor {
        return .{ .context = stub, .execute_fn = execute };
    }

    fn execute(context: *anyopaque, command: tab_commands.RenameTab) anyerror!tab_commands.RenameTabResult {
        const stub: *StubRenameTab = @ptrCast(@alignCast(context));
        std.debug.assert(command.label.len <= stub.last_label.len);

        stub.call_count += 1;
        stub.last_location = command.location;
        stub.last_label_len = @intCast(command.label.len);
        @memcpy(stub.last_label[0..command.label.len], command.label);

        if (stub.failure) |failure| {
            return failure;
        }

        return stub.result.?;
    }

    fn lastLabel(stub: *const StubRenameTab) []const u8 {
        return stub.last_label[0..stub.last_label_len];
    }
};

fn testingLocation() !schema.TabLocation {
    return .{
        .workspace = .{ .workspace = try schema.id.workspace(3) },
        .tab_id = try schema.id.tab(7),
    };
}

test "Controller maps a rename request and queues the canonical result" {
    const requested_location = try testingLocation();
    var canonical_location = requested_location;
    canonical_location.tab_id = try schema.id.tab(8);
    var responses: ResponseQueue = .{};
    var rename_stub: StubRenameTab = .{
        .result = try tab_commands.RenameTabResult.init(canonical_location, "canonical"),
    };
    var controller = Controller.init(&responses, rename_stub.executor());
    const request_id: schema.RequestId = @enumFromInt(11);

    try controller.renameTab(.{
        .request_id = request_id,
        .location = requested_location,
        .label = "requested",
    });

    try std.testing.expectEqual(@as(usize, 1), rename_stub.call_count);
    try std.testing.expectEqualDeep(requested_location, rename_stub.last_location.?);
    try std.testing.expectEqualStrings("requested", rename_stub.lastLabel());
    const response = responses.peek().?;
    try std.testing.expect(response.* == .tab_renamed);
    try std.testing.expectEqual(request_id, response.tab_renamed.request_id);
    try std.testing.expectEqualDeep(canonical_location, response.tab_renamed.location);
    try std.testing.expectEqualStrings("canonical", response.tab_renamed.labelSlice());
}

test "Controller maps rename command errors without inventing domain effects" {
    const location = try testingLocation();
    const cases = [_]struct {
        command_error: anyerror,
        failure_code: schema.FailureCode,
        message: []const u8,
    }{
        .{ .command_error = error.TabNotFound, .failure_code = .tab_not_found, .message = "tab not found" },
        .{ .command_error = error.InvalidTabLabel, .failure_code = .invalid_request, .message = "invalid tab label" },
    };

    for (cases, 0..) |case, index| {
        var responses: ResponseQueue = .{};
        var rename_stub: StubRenameTab = .{ .failure = case.command_error };
        var controller = Controller.init(&responses, rename_stub.executor());
        const request_id: schema.RequestId = @enumFromInt(index + 20);

        try controller.renameTab(.{
            .request_id = request_id,
            .location = location,
            .label = "requested",
        });

        try std.testing.expectEqual(@as(usize, 1), rename_stub.call_count);
        const response = responses.peek().?;
        try std.testing.expect(response.* == .request_failed);
        try std.testing.expectEqual(request_id, response.request_failed.request_id);
        try std.testing.expectEqual(case.failure_code, response.request_failed.code);
        try std.testing.expectEqualStrings(case.message, response.request_failed.message);
    }
}

test "Controller propagates unexpected command failures without a response" {
    var responses: ResponseQueue = .{};
    var rename_stub: StubRenameTab = .{ .failure = error.EventPublisherUnavailable };
    var controller = Controller.init(&responses, rename_stub.executor());

    try std.testing.expectError(error.EventPublisherUnavailable, controller.renameTab(.{
        .request_id = @enumFromInt(30),
        .location = try testingLocation(),
        .label = "requested",
    }));

    try std.testing.expectEqual(@as(usize, 1), rename_stub.call_count);
    try std.testing.expect(responses.peek() == null);
}
