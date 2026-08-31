//! Application use cases for leaving, entering and recovering a workspace handoff.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../model.zig");

const schema = core.schema;

pub const SelectionTarget = union(enum) {
    position: usize,
    workspace: schema.WorkspaceId,
};

pub const SelectionGate = struct {
    context: *anyopaque,
    pending: *const fn (*anyopaque) bool,
};

pub const SelectionEffects = struct {
    context: *anyopaque,
    request: *const fn (*anyopaque, schema.WorkspaceId) anyerror!void,
};

pub const SelectWorkspaceHandler = struct {
    model: *const client_model.Model,
    gate: SelectionGate,
    effects: SelectionEffects,

    /// Resolves one listed workspace target and requests a handoff only when
    /// it is known, different from the active workspace and not blocked.
    ///
    /// ```zig
    /// if (!try handler.execute(.{ .position = 1 })) return;
    /// ```
    pub fn execute(handler: *SelectWorkspaceHandler, target: SelectionTarget) !bool {
        if (handler.gate.pending(handler.gate.context)) {
            return false;
        }

        const workspace = switch (target) {
            .position => |position| handler.model.workspaceAtPosition(position) orelse return false,
            .workspace => |workspace| workspace,
        };
        if (!handler.model.knowsWorkspace(workspace)) {
            return false;
        }
        if (handler.model.workspaceLocation()) |current| switch (current) {
            .workspace => |active| {
                if (active == workspace) {
                    return false;
                }
            },
            .worktree => {},
        };

        try handler.effects.request(handler.effects.context, workspace);

        return true;
    }
};

pub const WorkspaceHandoff = struct {
    target: schema.PaneTarget,
    fallback_workspace: ?schema.WorkspaceId,
    size: schema.TerminalSize,
};

pub const WorkspaceHandoffGate = struct {
    context: *anyopaque,
    pending: *const fn (*anyopaque) bool,
};

pub const HandoffRequestEffects = struct {
    context: *anyopaque,
    detach: *const fn (*anyopaque) anyerror!void,
    send: *const fn (*anyopaque, WorkspaceHandoff) anyerror!void,
    restore: *const fn (*anyopaque) anyerror!void,
    release: *const fn (*anyopaque, *const client_model.WorkspaceDeparture) void,
};

pub const RequestWorkspaceHandoffHandler = struct {
    model: *client_model.Model,
    gate: WorkspaceHandoffGate,
    effects: HandoffRequestEffects,

    /// Delivers every detach before the open request, then commits departure.
    /// Local delivery failure leaves the semantic model intact and asks the
    /// adapter to restore canonical attachment state.
    ///
    /// ```zig
    /// const departure = try handler.execute(command);
    /// ```
    pub fn execute(handler: *RequestWorkspaceHandoffHandler, command: WorkspaceHandoff) !client_model.WorkspaceDeparture {
        if (handler.gate.pending(handler.gate.context)) {
            return error.WorkspaceSwitchWhileRequestPending;
        }

        handler.effects.detach(handler.effects.context) catch |err| {
            handler.effects.restore(handler.effects.context) catch {};
            return err;
        };
        handler.effects.send(handler.effects.context, command) catch |err| {
            handler.effects.restore(handler.effects.context) catch {};
            return err;
        };

        const departure = handler.model.departWorkspace();
        handler.effects.release(handler.effects.context, &departure);

        return departure;
    }
};

pub const WorkspaceArrivalDelivery = struct {
    context: *anyopaque,
    deliver: *const fn (*anyopaque, client_model.WorkspaceActivation) anyerror!void,
};

pub const ConfirmWorkspaceHandoffHandler = struct {
    model: *client_model.Model,
    delivery: WorkspaceArrivalDelivery,

    /// Commits a fully constructed workspace before delivering its exact
    /// operational activation. Delivery failure never rolls the model back.
    ///
    /// ```zig
    /// try handler.execute(arrival);
    /// ```
    pub fn execute(handler: *ConfirmWorkspaceHandoffHandler, arrival: client_model.WorkspaceArrival) !void {
        const activation = try handler.model.arriveWorkspace(arrival);

        try handler.delivery.deliver(handler.delivery.context, activation);
    }
};

pub const WorkspaceHandoffFailure = struct {
    fallback_workspace: ?schema.WorkspaceId,
    code: schema.FailureCode,
};

pub const WorkspaceRecovery = enum {
    retried,
    unrecoverable,
};

pub const WorkspaceRecoveryEffects = struct {
    context: *anyopaque,
    forget: *const fn (*anyopaque, schema.WorkspaceId) void,
    retry: *const fn (*anyopaque, schema.WorkspaceId) anyerror!void,
};

pub const RecoverWorkspaceHandoffHandler = struct {
    effects: WorkspaceRecoveryEffects,

    /// Retries the containing workspace only when a remembered pane vanished.
    /// Every other failure remains authoritative and is propagated by the
    /// dispatcher.
    ///
    /// ```zig
    /// const recovery = try handler.execute(failure);
    /// ```
    pub fn execute(handler: *RecoverWorkspaceHandoffHandler, failure: WorkspaceHandoffFailure) !WorkspaceRecovery {
        const workspace = failure.fallback_workspace orelse return .unrecoverable;
        if (failure.code != .pane_not_found) {
            return .unrecoverable;
        }

        handler.effects.forget(handler.effects.context, workspace);
        try handler.effects.retry(handler.effects.context, workspace);

        return .retried;
    }
};

const TestingModel = struct {
    model: *client_model.Model,
    location: schema.TabLocation,

    fn init(occupied: bool) !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();
        const location: schema.TabLocation = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        };
        if (occupied) {
            try model.workspace.bootstrap(@enumFromInt(1), location, .{ .cols = 20, .rows = 5 });
        }

        return .{ .model = model, .location = location };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }
};

const SelectionCapture = struct {
    blocked: bool = false,
    fail: bool = false,
    calls: usize = 0,
    requested: ?schema.WorkspaceId = null,

    fn gate(capture: *SelectionCapture) SelectionGate {
        return .{ .context = capture, .pending = pending };
    }

    fn port(capture: *SelectionCapture) SelectionEffects {
        return .{ .context = capture, .request = request };
    }

    fn pending(context: *anyopaque) bool {
        const capture: *SelectionCapture = @ptrCast(@alignCast(context));

        return capture.blocked;
    }

    fn request(context: *anyopaque, workspace: schema.WorkspaceId) !void {
        const capture: *SelectionCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.requested = workspace;
        if (capture.fail) {
            return error.SelectionDeliveryFailed;
        }
    }
};

fn prepareWorkspaceSelection(model: *client_model.Model) !void {
    _ = try model.reconcileWorkspaceList(.{
        .revision = 1,
        .entries = &.{
            .{ .workspace = @enumFromInt(1), .name = "main", .path = "/work/main", .tab_count = 1 },
            .{ .workspace = @enumFromInt(2), .name = "api", .path = "/work/api", .tab_count = 1 },
        },
    });
}

test "SelectWorkspaceHandler resolves listed positions and identities without mutation" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    try prepareWorkspaceSelection(testing.model);
    var capture: SelectionCapture = .{};
    var handler: SelectWorkspaceHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.port(),
    };
    const version = testing.model.version();

    try std.testing.expect(try handler.execute(.{ .position = 1 }));
    try std.testing.expectEqual(@as(schema.WorkspaceId, @enumFromInt(2)), capture.requested.?);
    try std.testing.expect(try handler.execute(.{ .workspace = @enumFromInt(2) }));

    try std.testing.expect(!try handler.execute(.{ .workspace = @enumFromInt(1) }));
    try std.testing.expect(!try handler.execute(.{ .workspace = @enumFromInt(9) }));
    try std.testing.expect(!try handler.execute(.{ .position = 2 }));
    capture.blocked = true;
    try std.testing.expect(!try handler.execute(.{ .position = 1 }));

    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    try std.testing.expectEqualDeep(version, testing.model.version());
}

test "SelectWorkspaceHandler propagates delivery failure without mutation" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    try prepareWorkspaceSelection(testing.model);
    var capture: SelectionCapture = .{ .fail = true };
    var handler: SelectWorkspaceHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.port(),
    };
    const version = testing.model.version();

    try std.testing.expectError(
        error.SelectionDeliveryFailed,
        handler.execute(.{ .workspace = @enumFromInt(2) }),
    );

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(@as(schema.WorkspaceId, @enumFromInt(2)), capture.requested.?);
    try std.testing.expectEqualDeep(version, testing.model.version());
}

test "SelectWorkspaceHandler permits base workspace selection from a worktree" {
    var testing = try TestingModel.init(false);
    defer testing.deinit();
    try testing.model.workspace.bootstrap(@enumFromInt(1), .{
        .workspace = .{ .worktree = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    }, .{ .cols = 20, .rows = 5 });
    try prepareWorkspaceSelection(testing.model);
    var capture: SelectionCapture = .{};
    var handler: SelectWorkspaceHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.port(),
    };
    const version = testing.model.version();

    try std.testing.expect(try handler.execute(.{ .workspace = @enumFromInt(1) }));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(@as(schema.WorkspaceId, @enumFromInt(1)), capture.requested.?);
    try std.testing.expectEqualDeep(version, testing.model.version());
}

const RequestEvent = enum {
    detach,
    send,
    restore,
    release,
};

const RequestCapture = struct {
    model: *const client_model.Model,
    blocked: bool = false,
    fail_detach: bool = false,
    fail_send: bool = false,
    events: [4]RequestEvent = undefined,
    event_count: usize = 0,
    command: ?WorkspaceHandoff = null,
    departure: ?client_model.WorkspaceDeparture = null,
    observed_commit: bool = false,

    fn gate(capture: *RequestCapture) WorkspaceHandoffGate {
        return .{ .context = capture, .pending = pending };
    }

    fn port(capture: *RequestCapture) HandoffRequestEffects {
        return .{
            .context = capture,
            .detach = detach,
            .send = send,
            .restore = restore,
            .release = release,
        };
    }

    fn pending(context: *anyopaque) bool {
        const capture: *RequestCapture = @ptrCast(@alignCast(context));
        return capture.blocked;
    }

    fn record(capture: *RequestCapture, event: RequestEvent) void {
        capture.events[capture.event_count] = event;
        capture.event_count += 1;
    }

    fn detach(context: *anyopaque) !void {
        const capture: *RequestCapture = @ptrCast(@alignCast(context));
        capture.record(.detach);
        if (capture.fail_detach) {
            return error.DetachFailed;
        }
    }

    fn send(context: *anyopaque, command: WorkspaceHandoff) !void {
        const capture: *RequestCapture = @ptrCast(@alignCast(context));
        capture.record(.send);
        capture.command = command;
        if (capture.fail_send) {
            return error.SendFailed;
        }
    }

    fn restore(context: *anyopaque) !void {
        const capture: *RequestCapture = @ptrCast(@alignCast(context));
        capture.record(.restore);
    }

    fn release(context: *anyopaque, departure: *const client_model.WorkspaceDeparture) void {
        const capture: *RequestCapture = @ptrCast(@alignCast(context));
        capture.record(.release);
        capture.departure = departure.*;
        capture.observed_commit = capture.model.workspaceLocation() == null and
            capture.model.version().workspace == 1;
    }
};

fn testingHandoff() WorkspaceHandoff {
    return .{
        .target = .{ .workspace = @enumFromInt(2) },
        .fallback_workspace = @enumFromInt(2),
        .size = .{ .cols = 30, .rows = 8 },
    };
}

test "RequestWorkspaceHandoffHandler orders effects before one departure commit" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    var capture: RequestCapture = .{ .model = testing.model };
    var handler: RequestWorkspaceHandoffHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.port(),
    };
    const command = testingHandoff();

    const departure = try handler.execute(command);

    try std.testing.expectEqualSlices(RequestEvent, &.{ .detach, .send, .release }, capture.events[0..capture.event_count]);
    try std.testing.expectEqualDeep(command, capture.command.?);
    try std.testing.expectEqualDeep(departure.source, capture.departure.?.source);
    try std.testing.expect(capture.observed_commit);
    try std.testing.expect(testing.model.workspaceLocation() == null);
}

test "RequestWorkspaceHandoffHandler gates without effects or model mutation" {
    var testing = try TestingModel.init(true);
    defer testing.deinit();
    var capture: RequestCapture = .{ .model = testing.model, .blocked = true };
    var handler: RequestWorkspaceHandoffHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.port(),
    };

    try std.testing.expectError(error.WorkspaceSwitchWhileRequestPending, handler.execute(testingHandoff()));

    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
    try std.testing.expectEqualDeep(testing.location, testing.model.activeTabLocation().?);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "RequestWorkspaceHandoffHandler restores local detach and send failures" {
    inline for (.{
        .{ .detach = true, .send = false, .expected = error.DetachFailed, .events = &[_]RequestEvent{ .detach, .restore } },
        .{ .detach = false, .send = true, .expected = error.SendFailed, .events = &[_]RequestEvent{ .detach, .send, .restore } },
    }) |scenario| {
        var testing = try TestingModel.init(true);
        defer testing.deinit();
        var capture: RequestCapture = .{
            .model = testing.model,
            .fail_detach = scenario.detach,
            .fail_send = scenario.send,
        };
        var handler: RequestWorkspaceHandoffHandler = .{
            .model = testing.model,
            .gate = capture.gate(),
            .effects = capture.port(),
        };

        try std.testing.expectError(scenario.expected, handler.execute(testingHandoff()));

        try std.testing.expectEqualSlices(RequestEvent, scenario.events, capture.events[0..capture.event_count]);
        try std.testing.expectEqualDeep(testing.location, testing.model.activeTabLocation().?);
        try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
    }
}

const ArrivalCapture = struct {
    model: *const client_model.Model,
    expected_before: client_model.Version = .{},
    calls: usize = 0,
    observed_commit: bool = false,
    fail: bool = false,

    fn port(capture: *ArrivalCapture) WorkspaceArrivalDelivery {
        return .{ .context = capture, .deliver = deliver };
    }

    fn deliver(context: *anyopaque, activation: client_model.WorkspaceActivation) !void {
        const capture: *ArrivalCapture = @ptrCast(@alignCast(context));
        const version = capture.model.version();
        capture.calls += 1;
        capture.observed_commit = std.meta.eql(capture.model.activeTabLocation().?, activation.location) and
            version.workspace == activation.workspace_revision and
            version.tabs == activation.tabs_revision and
            version.active_tab == activation.active_tab_revision and
            version.panes == activation.panes_revision and
            version.copy == activation.copy_revision and
            activation.workspace_revision_before == capture.expected_before.workspace and
            activation.tabs_revision_before == capture.expected_before.tabs and
            activation.active_tab_revision_before == capture.expected_before.active_tab and
            activation.panes_revision_before == capture.expected_before.panes and
            activation.copy_revision_before == capture.expected_before.copy and
            activation.workspace_revision_before +% 1 == activation.workspace_revision and
            activation.tabs_revision_before +% 1 == activation.tabs_revision and
            activation.active_tab_revision_before +% 1 == activation.active_tab_revision and
            activation.panes_revision_before +% 1 == activation.panes_revision and
            activation.copy_revision_before +% @intFromBool(activation.copy_released) == activation.copy_revision;
        if (capture.fail) {
            return error.ArrivalDeliveryFailed;
        }
    }
};

test "ConfirmWorkspaceHandoffHandler commits before delivery and retains failures" {
    inline for (.{ false, true }) |fail| {
        var testing = try TestingModel.init(true);
        defer testing.deinit();
        _ = testing.model.departWorkspace();
        const version_before = testing.model.version();
        var capture: ArrivalCapture = .{
            .model = testing.model,
            .expected_before = version_before,
            .fail = fail,
        };
        var handler: ConfirmWorkspaceHandoffHandler = .{
            .model = testing.model,
            .delivery = capture.port(),
        };
        const arrival: client_model.WorkspaceArrival = .{
            .pane_id = @enumFromInt(9),
            .location = testing.location,
            .size = .{ .cols = 30, .rows = 8 },
        };

        if (fail) {
            try std.testing.expectError(error.ArrivalDeliveryFailed, handler.execute(arrival));
        } else {
            try handler.execute(arrival);
        }

        try std.testing.expectEqual(@as(usize, 1), capture.calls);
        try std.testing.expect(capture.observed_commit);
        try std.testing.expectEqualDeep(testing.location, testing.model.activeTabLocation().?);
        const version = testing.model.version();
        try std.testing.expectEqual(version_before.workspace +% 1, version.workspace);
        try std.testing.expectEqual(version_before.tabs +% 1, version.tabs);
        try std.testing.expectEqual(version_before.active_tab +% 1, version.active_tab);
        try std.testing.expectEqual(version_before.panes +% 1, version.panes);
        try std.testing.expectEqual(version_before.copy, version.copy);
    }
}

test "ConfirmWorkspaceHandoffHandler rejects construction before delivery" {
    var testing = try TestingModel.init(false);
    defer testing.deinit();
    var capture: ArrivalCapture = .{ .model = testing.model };
    var handler: ConfirmWorkspaceHandoffHandler = .{
        .model = testing.model,
        .delivery = capture.port(),
    };

    try std.testing.expectError(error.InvalidPaneId, handler.execute(.{
        .pane_id = .invalid,
        .location = testing.location,
        .size = .{ .cols = 30, .rows = 8 },
    }));

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expect(testing.model.workspaceLocation() == null);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

const RecoveryCapture = struct {
    forgotten: ?schema.WorkspaceId = null,
    retried: ?schema.WorkspaceId = null,
    fail: bool = false,

    fn port(capture: *RecoveryCapture) WorkspaceRecoveryEffects {
        return .{ .context = capture, .forget = forget, .retry = retry };
    }

    fn forget(context: *anyopaque, workspace: schema.WorkspaceId) void {
        const capture: *RecoveryCapture = @ptrCast(@alignCast(context));
        capture.forgotten = workspace;
    }

    fn retry(context: *anyopaque, workspace: schema.WorkspaceId) !void {
        const capture: *RecoveryCapture = @ptrCast(@alignCast(context));
        capture.retried = workspace;
        if (capture.fail) {
            return error.RetryFailed;
        }
    }
};

test "RecoverWorkspaceHandoffHandler retries only a vanished remembered pane" {
    const workspace: schema.WorkspaceId = @enumFromInt(7);
    var capture: RecoveryCapture = .{};
    var handler: RecoverWorkspaceHandoffHandler = .{ .effects = capture.port() };

    try std.testing.expectEqual(WorkspaceRecovery.unrecoverable, try handler.execute(.{
        .fallback_workspace = null,
        .code = .pane_not_found,
    }));
    try std.testing.expectEqual(WorkspaceRecovery.unrecoverable, try handler.execute(.{
        .fallback_workspace = workspace,
        .code = .internal,
    }));
    try std.testing.expect(capture.forgotten == null);
    try std.testing.expect(capture.retried == null);

    try std.testing.expectEqual(WorkspaceRecovery.retried, try handler.execute(.{
        .fallback_workspace = workspace,
        .code = .pane_not_found,
    }));
    try std.testing.expectEqual(workspace, capture.forgotten.?);
    try std.testing.expectEqual(workspace, capture.retried.?);
}

test "RecoverWorkspaceHandoffHandler retains stale-bookmark removal after retry failure" {
    const workspace: schema.WorkspaceId = @enumFromInt(7);
    var capture: RecoveryCapture = .{ .fail = true };
    var handler: RecoverWorkspaceHandoffHandler = .{ .effects = capture.port() };

    try std.testing.expectError(error.RetryFailed, handler.execute(.{
        .fallback_workspace = workspace,
        .code = .pane_not_found,
    }));

    try std.testing.expectEqual(workspace, capture.forgotten.?);
    try std.testing.expectEqual(workspace, capture.retried.?);
}
