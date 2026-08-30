//! Application use cases for requesting and applying tab closure.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../model.zig");

const schema = core.schema;

pub const CloseTab = client_model.CloseTab;

pub const TabOperationGate = struct {
    context: *anyopaque,
    pending: *const fn (*anyopaque) bool,
};

pub const CloseRequestEffects = struct {
    context: *anyopaque,
    detach: *const fn (*anyopaque, schema.TabLocation) anyerror!void,
    send: *const fn (*anyopaque, schema.TabLocation) anyerror!void,
    restore: *const fn (*anyopaque, schema.TabLocation) anyerror!void,
};

pub const RequestCloseTabHandler = struct {
    model: *const client_model.Model,
    gate: TabOperationGate,
    effects: CloseRequestEffects,

    /// Detaches the active tab before sending its close request. A failure in
    /// either effect requests a snapshot to restore the provisional detach.
    ///
    /// ```zig
    /// const requested = try handler.execute();
    /// ```
    pub fn execute(handler: *RequestCloseTabHandler) !?schema.TabLocation {
        if (handler.gate.pending(handler.gate.context)) {
            return null;
        }

        const location = handler.model.activeTabLocation() orelse return null;
        handler.effects.detach(handler.effects.context, location) catch |err| {
            handler.effects.restore(handler.effects.context, location) catch |restore_err|
                return restore_err;
            return err;
        };
        handler.effects.send(handler.effects.context, location) catch |err| {
            handler.effects.restore(handler.effects.context, location) catch |restore_err|
                return restore_err;
            return err;
        };

        return location;
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

pub const ClosureEffects = struct {
    context: *anyopaque,
    apply: *const fn (*anyopaque, client_model.TabRemoval) anyerror!void,
};

pub const CloseTabHandler = struct {
    model: *client_model.Model,
    effects: ClosureEffects,

    /// Commits a canonical removal before releasing client resources.
    /// Missing tabs return null; effect failures preserve committed state.
    ///
    /// ```zig
    /// const removal = try handler.execute(command) orelse return;
    /// ```
    pub fn execute(handler: *CloseTabHandler, command: CloseTab) !?client_model.TabRemoval {
        const removal = try handler.model.closeTab(command) orelse return null;
        try handler.effects.apply(handler.effects.context, removal);

        return removal;
    }
};

const RequestStep = enum {
    detach,
    send,
    restore,
};

const RequestCapture = struct {
    blocked: bool = false,
    detach_failure: ?anyerror = null,
    send_failure: ?anyerror = null,
    restore_failure: ?anyerror = null,
    steps: [3]RequestStep = undefined,
    step_count: u8 = 0,

    fn gate(capture: *RequestCapture) TabOperationGate {
        return .{ .context = capture, .pending = pending };
    }

    fn requestEffects(capture: *RequestCapture) CloseRequestEffects {
        return .{
            .context = capture,
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

    fn detach(context: *anyopaque, _: schema.TabLocation) !void {
        const capture: *RequestCapture = @ptrCast(@alignCast(context));
        capture.record(.detach);
        if (capture.detach_failure) |failure| {
            return failure;
        }
    }

    fn send(context: *anyopaque, _: schema.TabLocation) !void {
        const capture: *RequestCapture = @ptrCast(@alignCast(context));
        capture.record(.send);
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

const ClosureCapture = struct {
    model: *const client_model.Model,
    expected_active: schema.TabLocation,
    calls: usize = 0,
    observed_commit: bool = false,
    fail: bool = false,

    fn port(capture: *ClosureCapture) ClosureEffects {
        return .{ .context = capture, .apply = apply };
    }

    fn apply(context: *anyopaque, removal: client_model.TabRemoval) !void {
        const capture: *ClosureCapture = @ptrCast(@alignCast(context));
        const version = capture.model.version();
        capture.calls += 1;
        capture.observed_commit = capture.model.workspace.indexOf(removal.removed.tab_id) == null and
            std.meta.eql(capture.model.activeTabLocation(), capture.expected_active) and
            version.tabs == 1 and
            version.active_tab == 1;

        if (capture.fail) {
            return error.ClosureSyncFailed;
        }
    }
};

const TestingModel = struct {
    model: *client_model.Model,
    first: schema.TabLocation,
    second: schema.TabLocation,

    fn init() !TestingModel {
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
        _ = try model.workspace.addCreated(.{
            .location = second,
            .position = 1,
            .label = "logs",
            .root_pane_id = @enumFromInt(2),
        }, .{ .cols = 20, .rows = 5 });
        try std.testing.expect(model.workspace.select(first.tab_id));

        return .{ .model = model, .first = first, .second = second };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }
};

test "RequestCloseTabHandler detaches before sending" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RequestCapture = .{ .blocked = true };
    var handler: RequestCloseTabHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.requestEffects(),
    };

    try std.testing.expect((try handler.execute()) == null);
    try std.testing.expectEqual(@as(usize, 0), capture.recorded().len);
    capture.blocked = false;

    try std.testing.expectEqualDeep(testing.first, (try handler.execute()).?);
    try std.testing.expectEqualSlices(RequestStep, &.{ .detach, .send }, capture.recorded());
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "RequestCloseTabHandler restores every provisional failure" {
    var testing = try TestingModel.init();
    defer testing.deinit();

    var detach_failure: RequestCapture = .{ .detach_failure = error.DetachFailed };
    var detach_handler: RequestCloseTabHandler = .{
        .model = testing.model,
        .gate = detach_failure.gate(),
        .effects = detach_failure.requestEffects(),
    };
    try std.testing.expectError(error.DetachFailed, detach_handler.execute());
    try std.testing.expectEqualSlices(
        RequestStep,
        &.{ .detach, .restore },
        detach_failure.recorded(),
    );

    var send_failure: RequestCapture = .{ .send_failure = error.SendFailed };
    var send_handler: RequestCloseTabHandler = .{
        .model = testing.model,
        .gate = send_failure.gate(),
        .effects = send_failure.requestEffects(),
    };
    try std.testing.expectError(error.SendFailed, send_handler.execute());
    try std.testing.expectEqualSlices(
        RequestStep,
        &.{ .detach, .send, .restore },
        send_failure.recorded(),
    );
}

test "RecoverCloseTabHandler restores only the still-active tab" {
    var testing = try TestingModel.init();
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

test "CloseTabHandler commits before releasing client resources" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var effects: ClosureCapture = .{
        .model = testing.model,
        .expected_active = testing.second,
    };
    var handler: CloseTabHandler = .{
        .model = testing.model,
        .effects = effects.port(),
    };

    const removal = (try handler.execute(.{
        .location = testing.first,
        .workspace_closed = false,
    })).?;

    try std.testing.expect(removal.was_active);
    try std.testing.expectEqualDeep(testing.second, removal.active.?);
    try std.testing.expectEqual(@as(usize, 1), effects.calls);
    try std.testing.expect(effects.observed_commit);
}

test "CloseTabHandler rejects invalid and missing removals without effects" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var effects: ClosureCapture = .{
        .model = testing.model,
        .expected_active = testing.first,
    };
    var handler: CloseTabHandler = .{
        .model = testing.model,
        .effects = effects.port(),
    };

    try std.testing.expectError(error.UnexpectedWorkspaceClosure, handler.execute(.{
        .location = testing.first,
        .workspace_closed = true,
    }));
    try std.testing.expect((try handler.execute(.{
        .location = .{
            .workspace = testing.first.workspace,
            .tab_id = @enumFromInt(9),
        },
        .workspace_closed = false,
    })) == null);

    try std.testing.expectEqual(@as(usize, 0), effects.calls);
    try std.testing.expectEqual(@as(usize, 2), testing.model.workspace.count);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "CloseTabHandler preserves a committed removal after effect failure" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var effects: ClosureCapture = .{
        .model = testing.model,
        .expected_active = testing.second,
        .fail = true,
    };
    var handler: CloseTabHandler = .{
        .model = testing.model,
        .effects = effects.port(),
    };

    try std.testing.expectError(error.ClosureSyncFailed, handler.execute(.{
        .location = testing.first,
        .workspace_closed = false,
    }));

    try std.testing.expectEqual(@as(usize, 1), testing.model.workspace.count);
    try std.testing.expectEqualDeep(testing.second, testing.model.activeTabLocation().?);
    try std.testing.expectEqual(@as(u64, 1), testing.model.version().tabs);
    try std.testing.expectEqual(@as(u64, 1), testing.model.version().active_tab);
    try std.testing.expect(effects.observed_commit);
}
