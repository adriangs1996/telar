//! Application use cases for requesting closure and applying tab removal.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../model.zig");

const schema = core.schema;

pub const TabCloseIntent = struct {
    location: schema.TabLocation,
};

pub const TabOperationGate = struct {
    context: *anyopaque,
    pending: *const fn (*anyopaque) bool,
};

pub const CloseRequestEffects = struct {
    context: *anyopaque,
    prepare: *const fn (*anyopaque, schema.TabLocation) anyerror!void,
    detach: *const fn (*anyopaque, schema.TabLocation) anyerror!void,
    send: *const fn (*anyopaque, TabCloseIntent) anyerror!void,
    restore: *const fn (*anyopaque, schema.TabLocation) anyerror!void,
};

pub const RequestCloseTabHandler = struct {
    model: *const client_model.Model,
    gate: TabOperationGate,
    effects: CloseRequestEffects,

    /// Verifies delivery capacity, detaches the active tab and sends one close
    /// intent. A failure after detachment requests canonical restoration.
    ///
    /// ```zig
    /// if (!try handler.execute()) {
    ///     return;
    /// }
    /// ```
    pub fn execute(handler: *RequestCloseTabHandler) !bool {
        if (handler.gate.pending(handler.gate.context)) {
            return false;
        }

        const location = handler.model.activeTabLocation() orelse return false;

        try handler.effects.prepare(handler.effects.context, location);
        handler.effects.detach(handler.effects.context, location) catch |err| {
            handler.effects.restore(handler.effects.context, location) catch |restore_err| {
                return restore_err;
            };
            return err;
        };

        handler.effects.send(handler.effects.context, .{ .location = location }) catch |err| {
            handler.effects.restore(handler.effects.context, location) catch |restore_err| {
                return restore_err;
            };
            return err;
        };

        return true;
    }
};

pub const CloseRecoveryEffects = struct {
    context: *anyopaque,
    restore: *const fn (*anyopaque, schema.TabLocation) anyerror!void,
};

pub const RecoverCloseTabHandler = struct {
    model: *const client_model.Model,
    effects: CloseRecoveryEffects,

    /// Restores a rejected close only while its tab remains active.
    ///
    /// ```zig
    /// _ = try handler.execute(location);
    /// ```
    pub fn execute(handler: *RecoverCloseTabHandler, location: schema.TabLocation) !bool {
        const active = handler.model.activeTabLocation() orelse return false;
        if (!std.meta.eql(active, location)) {
            return false;
        }

        try handler.effects.restore(handler.effects.context, location);
        return true;
    }
};

pub const RemovalTrigger = enum {
    requested,
    lifecycle,
};

pub const ApplyTabRemoval = struct {
    location: schema.TabLocation,
    workspace_removed: bool,
    previous_workspace: ?schema.WorkspaceId,
    trigger: RemovalTrigger,
};

pub const TabRemovalDirective = enum {
    continue_running,
    exit,
};

pub const RemovalEffects = struct {
    context: *anyopaque,
    retire_requests: *const fn (*anyopaque, schema.TabLocation) void,
    release_resources: *const fn (*anyopaque, client_model.TabRemoval) anyerror!void,
    forget_workspace: *const fn (*anyopaque, schema.WorkspaceLocation) void,
    request_workspace: *const fn (*anyopaque, schema.WorkspaceId) anyerror!void,
};

pub const ApplyTabRemovalHandler = struct {
    model: *client_model.Model,
    effects: RemovalEffects,

    /// Applies one canonical tab-removal fact and completes its client
    /// lifecycle. Repeated lifecycle facts are ignored; a missing requested
    /// removal is rejected. The final workspace either starts a handoff or
    /// asks the client loop to exit.
    ///
    /// ```zig
    /// const directive = try handler.execute(command);
    /// ```
    pub fn execute(handler: *ApplyTabRemovalHandler, command: ApplyTabRemoval) !TabRemovalDirective {
        try validateWorkspaceTransition(command);

        const removal = handler.model.removeTab(.{
            .location = command.location,
            .workspace_removed = command.workspace_removed,
        }) catch |err| switch (err) {
            error.UnexpectedWorkspace => if (command.trigger == .lifecycle) null else return err,
            else => return err,
        };

        const committed = removal orelse {
            if (command.trigger == .requested) {
                return error.UnexpectedTab;
            }

            handler.effects.retire_requests(handler.effects.context, command.location);
            return .continue_running;
        };

        handler.effects.retire_requests(handler.effects.context, committed.removed);
        try handler.effects.release_resources(handler.effects.context, committed);

        if (!committed.workspace_removed) {
            return .continue_running;
        }

        handler.effects.forget_workspace(handler.effects.context, committed.removed.workspace);
        const previous = command.previous_workspace orelse return .exit;
        try handler.effects.request_workspace(handler.effects.context, previous);

        return .continue_running;
    }
};

fn validateWorkspaceTransition(command: ApplyTabRemoval) !void {
    if (!command.workspace_removed and command.previous_workspace != null) {
        return error.UnexpectedPreviousWorkspace;
    }

    const previous = command.previous_workspace orelse return;
    const removed = switch (command.location.workspace) {
        .workspace => |workspace| workspace,
        .worktree => return error.InvalidWorkspaceSuccessor,
    };

    if (previous == removed) {
        return error.InvalidWorkspaceSuccessor;
    }
}

const RequestStep = enum {
    prepare,
    detach,
    send,
    restore,
};

const RequestCapture = struct {
    blocked: bool = false,
    prepare_failure: ?anyerror = null,
    detach_failure: ?anyerror = null,
    send_failure: ?anyerror = null,
    restore_failure: ?anyerror = null,
    intent: ?TabCloseIntent = null,
    steps: [4]RequestStep = undefined,
    step_count: u8 = 0,

    fn gate(capture: *RequestCapture) TabOperationGate {
        return .{ .context = capture, .pending = pending };
    }

    fn requestEffects(capture: *RequestCapture) CloseRequestEffects {
        return .{
            .context = capture,
            .prepare = prepare,
            .detach = detach,
            .send = send,
            .restore = restore,
        };
    }

    fn recoveryEffects(capture: *RequestCapture) CloseRecoveryEffects {
        return .{ .context = capture, .restore = restore };
    }

    fn pending(context: *anyopaque) bool {
        const capture: *RequestCapture = @ptrCast(@alignCast(context));
        return capture.blocked;
    }

    fn prepare(context: *anyopaque, _: schema.TabLocation) !void {
        const capture: *RequestCapture = @ptrCast(@alignCast(context));
        capture.record(.prepare);
        if (capture.prepare_failure) |failure| {
            return failure;
        }
    }

    fn detach(context: *anyopaque, _: schema.TabLocation) !void {
        const capture: *RequestCapture = @ptrCast(@alignCast(context));
        capture.record(.detach);
        if (capture.detach_failure) |failure| {
            return failure;
        }
    }

    fn send(context: *anyopaque, intent: TabCloseIntent) !void {
        const capture: *RequestCapture = @ptrCast(@alignCast(context));
        capture.record(.send);
        capture.intent = intent;
        if (capture.send_failure) |failure| {
            return failure;
        }
    }

    fn restore(context: *anyopaque, _: schema.TabLocation) !void {
        const capture: *RequestCapture = @ptrCast(@alignCast(context));
        capture.record(.restore);
        if (capture.restore_failure) |failure| {
            return failure;
        }
    }

    fn record(capture: *RequestCapture, step: RequestStep) void {
        capture.steps[capture.step_count] = step;
        capture.step_count += 1;
    }

    fn recorded(capture: *const RequestCapture) []const RequestStep {
        return capture.steps[0..capture.step_count];
    }
};

const RemovalStep = enum {
    retire_requests,
    release_resources,
    forget_workspace,
    request_workspace,
};

const RemovalCapture = struct {
    model: *const client_model.Model,
    steps: [4]RemovalStep = undefined,
    step_count: u8 = 0,
    retired: ?schema.TabLocation = null,
    forgotten: ?schema.WorkspaceLocation = null,
    requested: ?schema.WorkspaceId = null,
    observed_commit: bool = false,
    release_failure: ?anyerror = null,
    request_failure: ?anyerror = null,

    fn port(capture: *RemovalCapture) RemovalEffects {
        return .{
            .context = capture,
            .retire_requests = retireRequests,
            .release_resources = releaseResources,
            .forget_workspace = forgetWorkspace,
            .request_workspace = requestWorkspace,
        };
    }

    fn retireRequests(context: *anyopaque, location: schema.TabLocation) void {
        const capture: *RemovalCapture = @ptrCast(@alignCast(context));
        capture.record(.retire_requests);
        capture.retired = location;
    }

    fn releaseResources(context: *anyopaque, removal: client_model.TabRemoval) !void {
        const capture: *RemovalCapture = @ptrCast(@alignCast(context));
        capture.record(.release_resources);
        capture.observed_commit = capture.model.tabLocation(removal.removed.tab_id) == null and
            (capture.model.workspaceLocation() == null) == removal.workspace_removed;

        if (capture.release_failure) |failure| {
            return failure;
        }
    }

    fn forgetWorkspace(context: *anyopaque, workspace: schema.WorkspaceLocation) void {
        const capture: *RemovalCapture = @ptrCast(@alignCast(context));
        capture.record(.forget_workspace);
        capture.forgotten = workspace;
    }

    fn requestWorkspace(context: *anyopaque, workspace: schema.WorkspaceId) !void {
        const capture: *RemovalCapture = @ptrCast(@alignCast(context));
        capture.record(.request_workspace);
        capture.requested = workspace;

        if (capture.request_failure) |failure| {
            return failure;
        }
    }

    fn record(capture: *RemovalCapture, step: RemovalStep) void {
        capture.steps[capture.step_count] = step;
        capture.step_count += 1;
    }

    fn recorded(capture: *const RemovalCapture) []const RemovalStep {
        return capture.steps[0..capture.step_count];
    }
};

const TestingModel = struct {
    model: *client_model.Model,
    first: schema.TabLocation,
    second: schema.TabLocation,

    fn init(with_second: bool) !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();

        const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
        const first: schema.TabLocation = .{
            .workspace = workspace,
            .tab_id = @enumFromInt(1),
        };
        const second: schema.TabLocation = .{
            .workspace = workspace,
            .tab_id = @enumFromInt(2),
        };
        try model.workspace.bootstrap(@enumFromInt(1), first, .{ .cols = 20, .rows = 5 });
        if (with_second) {
            _ = try model.workspace.addCreated(.{
                .location = second,
                .position = 1,
                .label = "logs",
                .root_pane_id = @enumFromInt(2),
            }, .{ .cols = 20, .rows = 5 });
            try std.testing.expect(model.workspace.select(first.tab_id));
        }

        return .{ .model = model, .first = first, .second = second };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }
};

test "tab close request prepares and detaches before delivery" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    var capture: RequestCapture = .{ .blocked = true };
    var handler: RequestCloseTabHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.requestEffects(),
    };

    try std.testing.expect(!try handler.execute());
    try std.testing.expectEqual(@as(usize, 0), capture.recorded().len);
    capture.blocked = false;

    try std.testing.expect(try handler.execute());
    try std.testing.expectEqualSlices(RequestStep, &.{ .prepare, .detach, .send }, capture.recorded());
    try std.testing.expectEqualDeep(testing.first, capture.intent.?.location);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "tab close request suppresses an absent active tab" {
    var testing = try TestingModel.init(false);
    defer testing.deinit();
    _ = testing.model.departWorkspace();
    var capture: RequestCapture = .{};
    var handler: RequestCloseTabHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.requestEffects(),
    };

    try std.testing.expect(!try handler.execute());
    try std.testing.expectEqual(@as(usize, 0), capture.recorded().len);
}

test "tab close request rejects preparation without provisional effects" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    var capture: RequestCapture = .{ .prepare_failure = error.NoDeliveryCapacity };
    var handler: RequestCloseTabHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.requestEffects(),
    };

    try std.testing.expectError(error.NoDeliveryCapacity, handler.execute());
    try std.testing.expectEqualSlices(RequestStep, &.{.prepare}, capture.recorded());
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "tab close request restores every failure after preparation" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();

    var detach_failure: RequestCapture = .{ .detach_failure = error.DetachFailed };
    var detach_handler: RequestCloseTabHandler = .{
        .model = testing.model,
        .gate = detach_failure.gate(),
        .effects = detach_failure.requestEffects(),
    };
    try std.testing.expectError(error.DetachFailed, detach_handler.execute());
    try std.testing.expectEqualSlices(RequestStep, &.{ .prepare, .detach, .restore }, detach_failure.recorded());

    var send_failure: RequestCapture = .{ .send_failure = error.SendFailed };
    var send_handler: RequestCloseTabHandler = .{
        .model = testing.model,
        .gate = send_failure.gate(),
        .effects = send_failure.requestEffects(),
    };
    try std.testing.expectError(error.SendFailed, send_handler.execute());
    try std.testing.expectEqualSlices(RequestStep, &.{ .prepare, .detach, .send, .restore }, send_failure.recorded());
}

test "close rejection restores only the still-active tab" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    var capture: RequestCapture = .{};
    var handler: RecoverCloseTabHandler = .{
        .model = testing.model,
        .effects = capture.recoveryEffects(),
    };

    try std.testing.expect(!try handler.execute(testing.second));
    try std.testing.expectEqual(@as(usize, 0), capture.recorded().len);
    try std.testing.expect(try handler.execute(testing.first));
    try std.testing.expectEqualSlices(RequestStep, &.{.restore}, capture.recorded());
}

test "tab removal commits before retiring requests and resources" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    var capture: RemovalCapture = .{ .model = testing.model };
    var handler: ApplyTabRemovalHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    const directive = try handler.execute(.{
        .location = testing.first,
        .workspace_removed = false,
        .previous_workspace = null,
        .trigger = .requested,
    });

    try std.testing.expectEqual(TabRemovalDirective.continue_running, directive);
    try std.testing.expectEqualSlices(RemovalStep, &.{ .retire_requests, .release_resources }, capture.recorded());
    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqualDeep(testing.second, testing.model.activeTabLocation().?);
    try std.testing.expectEqual(@as(u64, 1), testing.model.version().tabs);
    try std.testing.expectEqual(@as(u64, 1), testing.model.version().active_tab);
}

test "requested tab removal rejects invalid or missing canonical state" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    var capture: RemovalCapture = .{ .model = testing.model };
    var handler: ApplyTabRemovalHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    try std.testing.expectError(error.UnexpectedPreviousWorkspace, handler.execute(.{
        .location = testing.first,
        .workspace_removed = false,
        .previous_workspace = @enumFromInt(9),
        .trigger = .requested,
    }));
    try std.testing.expectError(error.UnexpectedWorkspaceRemoval, handler.execute(.{
        .location = testing.first,
        .workspace_removed = true,
        .previous_workspace = null,
        .trigger = .requested,
    }));
    try std.testing.expectError(error.UnexpectedTab, handler.execute(.{
        .location = .{
            .workspace = testing.first.workspace,
            .tab_id = @enumFromInt(9),
        },
        .workspace_removed = false,
        .previous_workspace = null,
        .trigger = .requested,
    }));

    try std.testing.expectEqual(@as(usize, 0), capture.recorded().len);
    try std.testing.expectEqual(@as(usize, 2), testing.model.workspace.count);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "repeated lifecycle tab removal retires stale requests without mutation" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    var capture: RemovalCapture = .{ .model = testing.model };
    var handler: ApplyTabRemovalHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };
    const missing: schema.TabLocation = .{
        .workspace = testing.first.workspace,
        .tab_id = @enumFromInt(9),
    };

    try std.testing.expectEqual(TabRemovalDirective.continue_running, try handler.execute(.{
        .location = missing,
        .workspace_removed = false,
        .previous_workspace = null,
        .trigger = .lifecycle,
    }));

    try std.testing.expectEqualSlices(RemovalStep, &.{.retire_requests}, capture.recorded());
    try std.testing.expectEqualDeep(missing, capture.retired.?);
    try std.testing.expectEqual(@as(usize, 2), testing.model.workspace.count);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "stale lifecycle tab removal from a departed workspace is ignored" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    const stale = testing.second;
    _ = testing.model.departWorkspace();
    try testing.model.workspace.bootstrap(@enumFromInt(7), .{
        .workspace = .{ .workspace = @enumFromInt(7) },
        .tab_id = @enumFromInt(7),
    }, .{ .cols = 20, .rows = 5 });
    var capture: RemovalCapture = .{ .model = testing.model };
    var handler: ApplyTabRemovalHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };
    const version = testing.model.version();

    try std.testing.expectEqual(TabRemovalDirective.continue_running, try handler.execute(.{
        .location = stale,
        .workspace_removed = false,
        .previous_workspace = null,
        .trigger = .lifecycle,
    }));

    try std.testing.expectEqualSlices(RemovalStep, &.{.retire_requests}, capture.recorded());
    try std.testing.expectEqualDeep(version, testing.model.version());
}

test "removing the final workspace chooses exit or canonical predecessor" {
    inline for (.{
        .{ .previous = @as(?schema.WorkspaceId, null), .expected = TabRemovalDirective.exit, .handoff = false },
        .{ .previous = @as(?schema.WorkspaceId, @enumFromInt(9)), .expected = TabRemovalDirective.continue_running, .handoff = true },
    }) |scenario| {
        var testing = try TestingModel.init(false);
        defer testing.deinit();
        var capture: RemovalCapture = .{ .model = testing.model };
        var handler: ApplyTabRemovalHandler = .{
            .model = testing.model,
            .effects = capture.port(),
        };

        try std.testing.expectEqual(scenario.expected, try handler.execute(.{
            .location = testing.first,
            .workspace_removed = true,
            .previous_workspace = scenario.previous,
            .trigger = .lifecycle,
        }));

        const expected_steps: []const RemovalStep = if (scenario.handoff)
            &.{ .retire_requests, .release_resources, .forget_workspace, .request_workspace }
        else
            &.{ .retire_requests, .release_resources, .forget_workspace };
        try std.testing.expectEqualSlices(RemovalStep, expected_steps, capture.recorded());
        try std.testing.expect(capture.observed_commit);
        try std.testing.expectEqualDeep(testing.first.workspace, capture.forgotten.?);
        try std.testing.expectEqual(scenario.previous, capture.requested);
        try std.testing.expect(testing.model.workspaceLocation() == null);
    }
}

test "tab removal preserves its commit after resource failure" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    var capture: RemovalCapture = .{
        .model = testing.model,
        .release_failure = error.ResourceSyncFailed,
    };
    var handler: ApplyTabRemovalHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    try std.testing.expectError(error.ResourceSyncFailed, handler.execute(.{
        .location = testing.first,
        .workspace_removed = false,
        .previous_workspace = null,
        .trigger = .requested,
    }));

    try std.testing.expectEqualSlices(RemovalStep, &.{ .retire_requests, .release_resources }, capture.recorded());
    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqualDeep(testing.second, testing.model.activeTabLocation().?);
}

test "workspace handoff failure retains removal and forgotten navigation" {
    var testing = try TestingModel.init(false);
    defer testing.deinit();
    var capture: RemovalCapture = .{
        .model = testing.model,
        .request_failure = error.HandoffFailed,
    };
    var handler: ApplyTabRemovalHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    try std.testing.expectError(error.HandoffFailed, handler.execute(.{
        .location = testing.first,
        .workspace_removed = true,
        .previous_workspace = @enumFromInt(9),
        .trigger = .lifecycle,
    }));

    try std.testing.expectEqualSlices(
        RemovalStep,
        &.{ .retire_requests, .release_resources, .forget_workspace, .request_workspace },
        capture.recorded(),
    );
    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqualDeep(testing.first.workspace, capture.forgotten.?);
    try std.testing.expectEqual(@as(schema.WorkspaceId, @enumFromInt(9)), capture.requested.?);
    try std.testing.expect(testing.model.workspaceLocation() == null);
}
