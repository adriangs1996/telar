//! Request-scoped controller for the close-tab protocol message.

const std = @import("std");
const core = @import("telar-core");
const close_tab_commands = @import("../commands/close_tab.zig");
const delivery_mod = @import("../delivery/root.zig");
const workspace_mod = @import("../../workspace/root.zig");

const schema = core.schema;
const ResponseQueue = delivery_mod.ResponseQueue;

pub const Controller = struct {
    responses: *ResponseQueue,
    close_tab: close_tab_commands.CloseTabExecutor,

    /// Creates one controller for the lifetime of a close-tab request.
    ///
    /// ```zig
    /// var controller = Controller.init(&responses, handler.executor());
    /// ```
    pub fn init(responses: *ResponseQueue, close_tab: close_tab_commands.CloseTabExecutor) Controller {
        return .{ .responses = responses, .close_tab = close_tab };
    }

    /// Translates the wire request into an application command and queues the
    /// canonical removal result or one expected protocol failure.
    ///
    /// ```zig
    /// try controller.closeTab(request);
    /// ```
    pub fn closeTab(controller: *Controller, request: schema.CloseTab) !void {
        const removed = controller.close_tab.execute(.{ .location = request.location }) catch |err| {
            switch (err) {
                error.TabNotFound => try controller.queueTabNotFound(request.request_id),
                else => return err,
            }

            return;
        };

        try controller.responses.push(.{ .tab_closed = .{
            .request_id = request.request_id,
            .location = removed.location,
            .workspace_closed = removed.workspace_removed,
            .previous_workspace = removed.previous_workspace,
        } });
    }

    fn queueTabNotFound(controller: *Controller, request_id: schema.RequestId) !void {
        try controller.responses.push(.{ .request_failed = .{
            .request_id = request_id,
            .code = .tab_not_found,
            .message = "tab not found",
        } });
    }
};

const StubCloseTab = struct {
    result: ?close_tab_commands.CloseTabResult = null,
    failure: ?anyerror = null,
    call_count: usize = 0,
    last_location: ?schema.TabLocation = null,

    fn executor(stub: *StubCloseTab) close_tab_commands.CloseTabExecutor {
        return .{ .context = stub, .execute_fn = execute };
    }

    fn execute(context: *anyopaque, command: close_tab_commands.CloseTab) !close_tab_commands.CloseTabResult {
        const stub: *StubCloseTab = @ptrCast(@alignCast(context));
        stub.call_count += 1;
        stub.last_location = command.location;

        if (stub.failure) |failure| {
            return failure;
        }

        return stub.result.?;
    }
};

fn testingLocation(workspace_id: u64, tab_id: u64) !schema.TabLocation {
    return .{
        .workspace = .{ .workspace = try schema.id.workspace(workspace_id) },
        .tab_id = try schema.id.tab(tab_id),
    };
}

test "Controller maps tab-only and whole-workspace removal results" {
    const requested = try testingLocation(3, 7);
    const canonical = try testingLocation(3, 8);
    const previous = try schema.id.workspace(2);
    const cases = [_]struct {
        result: workspace_mod.TabRemoved,
        workspace_closed: bool,
        previous_workspace: ?schema.WorkspaceId,
    }{
        .{
            .result = try workspace_mod.TabRemoved.init(canonical, false, null),
            .workspace_closed = false,
            .previous_workspace = null,
        },
        .{
            .result = try workspace_mod.TabRemoved.init(canonical, true, previous),
            .workspace_closed = true,
            .previous_workspace = previous,
        },
    };

    for (cases, 0..) |case, index| {
        var responses: ResponseQueue = .{};
        var stub: StubCloseTab = .{ .result = case.result };
        var controller = Controller.init(&responses, stub.executor());
        const request_id: schema.RequestId = @enumFromInt(index + 11);

        try controller.closeTab(.{
            .request_id = request_id,
            .location = requested,
        });

        try std.testing.expectEqual(@as(usize, 1), stub.call_count);
        try std.testing.expectEqualDeep(requested, stub.last_location.?);
        const response = responses.peek().?;
        try std.testing.expect(response.* == .tab_closed);
        try std.testing.expectEqual(request_id, response.tab_closed.request_id);
        try std.testing.expectEqualDeep(canonical, response.tab_closed.location);
        try std.testing.expectEqual(case.workspace_closed, response.tab_closed.workspace_closed);
        try std.testing.expectEqual(case.previous_workspace, response.tab_closed.previous_workspace);
    }
}

test "Controller maps a missing tab without inventing a success" {
    const location = try testingLocation(3, 7);
    const request_id: schema.RequestId = @enumFromInt(20);
    var responses: ResponseQueue = .{};
    var stub: StubCloseTab = .{ .failure = error.TabNotFound };
    var controller = Controller.init(&responses, stub.executor());

    try controller.closeTab(.{
        .request_id = request_id,
        .location = location,
    });

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    const response = responses.peek().?;
    try std.testing.expect(response.* == .request_failed);
    try std.testing.expectEqual(request_id, response.request_failed.request_id);
    try std.testing.expectEqual(schema.FailureCode.tab_not_found, response.request_failed.code);
    try std.testing.expectEqualStrings("tab not found", response.request_failed.message);
}

test "Controller propagates unexpected close-tab failures without a response" {
    var responses: ResponseQueue = .{};
    var stub: StubCloseTab = .{ .failure = error.EventPublisherUnavailable };
    var controller = Controller.init(&responses, stub.executor());

    try std.testing.expectError(error.EventPublisherUnavailable, controller.closeTab(.{
        .request_id = @enumFromInt(30),
        .location = try testingLocation(3, 7),
    }));

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expect(responses.peek() == null);
}
