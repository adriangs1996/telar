//! Application use cases for requesting closure and applying tab removal.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../model.zig");
const tab_close_preparation = @import("tab_close_preparation.zig");
const tab_snapshot_recovery = @import("tab_snapshot_recovery.zig");

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
    detach: *const fn (*anyopaque, schema.TabLocation) anyerror!void,
    send: *const fn (*anyopaque, TabCloseIntent) anyerror!void,
};

pub const RequestCloseTabHandler = struct {
    model: *const client_model.Model,
    gate: TabOperationGate,
    preparation: tab_close_preparation.PrepareTabCloseHandler,
    snapshots: tab_snapshot_recovery.RequestTabSnapshotRecoveryHandler,
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

        try handler.preparation.execute(handler.model, location);
        handler.effects.detach(handler.effects.context, location) catch |err| {
            _ = handler.snapshots.execute(location) catch |restore_err| {
                return restore_err;
            };
            return err;
        };

        handler.effects.send(handler.effects.context, .{ .location = location }) catch |err| {
            _ = handler.snapshots.execute(location) catch |restore_err| {
                return restore_err;
            };
            return err;
        };

        return true;
    }
};

pub const RecoverCloseTabHandler = struct {
    model: *const client_model.Model,
    snapshots: tab_snapshot_recovery.RequestTabSnapshotRecoveryHandler,

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

        _ = try handler.snapshots.execute(location);
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

pub const RemovalDelivery = struct {
    context: *anyopaque,
    deliver: *const fn (*anyopaque, client_model.TabRemovalCommit, ?schema.WorkspaceId) anyerror!TabRemovalDirective,
};

pub const ApplyTabRemovalHandler = struct {
    model: *client_model.Model,
    delivery: RemovalDelivery,

    /// Validates and commits one canonical tab-removal fact before delegating
    /// its exact removed or stale result. Requested absence is rejected while
    /// lifecycle absence remains an idempotent delivery.
    ///
    /// ```zig
    /// const directive = try handler.execute(command);
    /// ```
    pub fn execute(handler: *ApplyTabRemovalHandler, command: ApplyTabRemoval) !TabRemovalDirective {
        try validateWorkspaceTransition(command);

        const commit = try handler.model.removeTab(.{
            .location = command.location,
            .workspace_removed = command.workspace_removed,
        });

        if (commit == .stale and command.trigger == .requested) {
            return switch (commit.stale.absence) {
                .workspace => error.UnexpectedWorkspace,
                .tab => error.UnexpectedTab,
            };
        }

        return handler.delivery.deliver(
            handler.delivery.context,
            commit,
            command.previous_workspace,
        );
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
            .detach = detach,
            .send = send,
        };
    }

    fn preparation(capture: *RequestCapture) tab_close_preparation.PrepareTabCloseHandler {
        return .{
            .requests = .{
                .context = capture,
                .ensure = prepare,
            },
            .deliveries = .{
                .context = capture,
                .available = availableCapacity,
            },
            .pending_attachments = .{
                .context = capture,
                .pending = attachmentPending,
            },
        };
    }

    fn snapshots(capture: *RequestCapture) tab_snapshot_recovery.RequestTabSnapshotRecoveryHandler {
        return .{ .effects = .{
            .context = capture,
            .pending = snapshotPending,
            .request = restore,
        } };
    }

    fn pending(context: *anyopaque) bool {
        const capture: *RequestCapture = @ptrCast(@alignCast(context));
        return capture.blocked;
    }

    fn prepare(context: *anyopaque, _: u64) !void {
        const capture: *RequestCapture = @ptrCast(@alignCast(context));
        capture.record(.prepare);
        if (capture.prepare_failure) |failure| {
            return failure;
        }
    }

    fn availableCapacity(_: *anyopaque) usize {
        return std.math.maxInt(usize);
    }

    fn attachmentPending(_: *anyopaque, _: schema.PaneId) bool {
        return false;
    }

    fn snapshotPending(_: *anyopaque) bool {
        return false;
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

const RemovalCapture = struct {
    model: *const client_model.Model,
    calls: usize = 0,
    commit: ?client_model.TabRemovalCommit = null,
    previous_workspace: ?schema.WorkspaceId = null,
    directive: TabRemovalDirective = .continue_running,
    observed_commit: bool = false,
    failure: ?anyerror = null,

    fn port(capture: *RemovalCapture) RemovalDelivery {
        return .{
            .context = capture,
            .deliver = deliver,
        };
    }

    fn deliver(context: *anyopaque, commit: client_model.TabRemovalCommit, previous_workspace: ?schema.WorkspaceId) !TabRemovalDirective {
        const capture: *RemovalCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.commit = commit;
        capture.previous_workspace = previous_workspace;
        capture.observed_commit = capture.observesCommit(commit);
        if (capture.failure) |failure| {
            return failure;
        }

        return capture.directive;
    }

    fn observesCommit(capture: *const RemovalCapture, commit: client_model.TabRemovalCommit) bool {
        const version = capture.model.version();
        return switch (commit) {
            .removed => |removal| capture.model.tabLocation(removal.removed.tab_id) == null and
                (capture.model.workspaceLocation() == null) == removal.workspace_removed and
                version.workspace == removal.workspace_revision and
                version.tabs == removal.tabs_revision and
                version.active_tab == removal.active_tab_revision and
                version.panes == removal.panes_revision and
                version.copy == removal.copy_revision,
            .stale => |stale| version.workspace == stale.workspace_revision and
                version.tabs == stale.tabs_revision and
                version.active_tab == stale.active_tab_revision and
                version.panes == stale.panes_revision and
                version.copy == stale.copy_revision,
        };
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
        .preparation = capture.preparation(),
        .snapshots = capture.snapshots(),
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
        .preparation = capture.preparation(),
        .snapshots = capture.snapshots(),
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
        .preparation = capture.preparation(),
        .snapshots = capture.snapshots(),
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
        .preparation = detach_failure.preparation(),
        .snapshots = detach_failure.snapshots(),
        .effects = detach_failure.requestEffects(),
    };
    try std.testing.expectError(error.DetachFailed, detach_handler.execute());
    try std.testing.expectEqualSlices(RequestStep, &.{ .prepare, .detach, .restore }, detach_failure.recorded());

    var send_failure: RequestCapture = .{ .send_failure = error.SendFailed };
    var send_handler: RequestCloseTabHandler = .{
        .model = testing.model,
        .gate = send_failure.gate(),
        .preparation = send_failure.preparation(),
        .snapshots = send_failure.snapshots(),
        .effects = send_failure.requestEffects(),
    };
    try std.testing.expectError(error.SendFailed, send_handler.execute());
    try std.testing.expectEqualSlices(RequestStep, &.{ .prepare, .detach, .send, .restore }, send_failure.recorded());
}

test "tab close request reports a failed repair after provisional failure" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    var capture: RequestCapture = .{
        .send_failure = error.SendFailed,
        .restore_failure = error.RestoreFailed,
    };
    var handler: RequestCloseTabHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .preparation = capture.preparation(),
        .snapshots = capture.snapshots(),
        .effects = capture.requestEffects(),
    };

    try std.testing.expectError(error.RestoreFailed, handler.execute());
    try std.testing.expectEqualSlices(RequestStep, &.{ .prepare, .detach, .send, .restore }, capture.recorded());
}

test "close rejection restores only the still-active tab" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    var capture: RequestCapture = .{};
    var handler: RecoverCloseTabHandler = .{
        .model = testing.model,
        .snapshots = capture.snapshots(),
    };

    try std.testing.expect(!try handler.execute(testing.second));
    try std.testing.expectEqual(@as(usize, 0), capture.recorded().len);
    try std.testing.expect(try handler.execute(testing.first));
    try std.testing.expectEqualSlices(RequestStep, &.{.restore}, capture.recorded());
}

test "tab removal commits before delivery" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    var capture: RemovalCapture = .{ .model = testing.model };
    var handler: ApplyTabRemovalHandler = .{
        .model = testing.model,
        .delivery = capture.port(),
    };

    const directive = try handler.execute(.{
        .location = testing.first,
        .workspace_removed = false,
        .previous_workspace = null,
        .trigger = .requested,
    });

    try std.testing.expectEqual(TabRemovalDirective.continue_running, directive);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.commit.? == .removed);
    try std.testing.expect(capture.previous_workspace == null);
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
        .delivery = capture.port(),
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

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expectEqual(@as(usize, 2), testing.model.workspace.count);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "repeated lifecycle tab removal delivers an exact stale commit without mutation" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    var capture: RemovalCapture = .{ .model = testing.model };
    var handler: ApplyTabRemovalHandler = .{
        .model = testing.model,
        .delivery = capture.port(),
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

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.commit.? == .stale);
    try std.testing.expectEqualDeep(missing, capture.commit.?.stale.location);
    try std.testing.expectEqual(client_model.TabRemovalAbsence.tab, capture.commit.?.stale.absence);
    try std.testing.expect(capture.observed_commit);
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
        .delivery = capture.port(),
    };
    const version = testing.model.version();

    try std.testing.expectEqual(TabRemovalDirective.continue_running, try handler.execute(.{
        .location = stale,
        .workspace_removed = false,
        .previous_workspace = null,
        .trigger = .lifecycle,
    }));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.commit.? == .stale);
    try std.testing.expectEqual(client_model.TabRemovalAbsence.workspace, capture.commit.?.stale.absence);
    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqualDeep(version, testing.model.version());
}

test "final workspace removal propagates the delivery directive and predecessor" {
    inline for (.{
        .{ .previous = @as(?schema.WorkspaceId, null), .expected = TabRemovalDirective.exit },
        .{ .previous = @as(?schema.WorkspaceId, @enumFromInt(9)), .expected = TabRemovalDirective.continue_running },
    }) |scenario| {
        var testing = try TestingModel.init(false);
        defer testing.deinit();
        var capture: RemovalCapture = .{
            .model = testing.model,
            .directive = scenario.expected,
        };
        var handler: ApplyTabRemovalHandler = .{
            .model = testing.model,
            .delivery = capture.port(),
        };

        try std.testing.expectEqual(scenario.expected, try handler.execute(.{
            .location = testing.first,
            .workspace_removed = true,
            .previous_workspace = scenario.previous,
            .trigger = .lifecycle,
        }));

        try std.testing.expectEqual(@as(usize, 1), capture.calls);
        try std.testing.expect(capture.commit.? == .removed);
        try std.testing.expect(capture.observed_commit);
        try std.testing.expectEqual(scenario.previous, capture.previous_workspace);
        try std.testing.expect(testing.model.workspaceLocation() == null);
    }
}

test "tab removal preserves its commit after delivery failure" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    var capture: RemovalCapture = .{
        .model = testing.model,
        .failure = error.ResourceSyncFailed,
    };
    var handler: ApplyTabRemovalHandler = .{
        .model = testing.model,
        .delivery = capture.port(),
    };

    try std.testing.expectError(error.ResourceSyncFailed, handler.execute(.{
        .location = testing.first,
        .workspace_removed = false,
        .previous_workspace = null,
        .trigger = .requested,
    }));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqualDeep(testing.second, testing.model.activeTabLocation().?);
}

test "final removal preserves its commit after delivery failure" {
    var testing = try TestingModel.init(false);
    defer testing.deinit();
    var capture: RemovalCapture = .{
        .model = testing.model,
        .failure = error.HandoffFailed,
    };
    var handler: ApplyTabRemovalHandler = .{
        .model = testing.model,
        .delivery = capture.port(),
    };

    try std.testing.expectError(error.HandoffFailed, handler.execute(.{
        .location = testing.first,
        .workspace_removed = true,
        .previous_workspace = @enumFromInt(9),
        .trigger = .lifecycle,
    }));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(@as(?schema.WorkspaceId, @enumFromInt(9)), capture.previous_workspace);
    try std.testing.expect(testing.model.workspaceLocation() == null);
}
