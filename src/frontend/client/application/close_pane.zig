//! Client use cases for requesting pane closure and applying pane exit.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../model.zig");

const schema = core.schema;

pub const PaneClosure = client_model.PaneClosure;
pub const PaneExit = client_model.PaneExit;

pub const PaneOperationGate = struct {
    context: *anyopaque,
    pending: *const fn (*anyopaque) bool,
};

pub const CloseRequestEffects = struct {
    context: *anyopaque,
    send: *const fn (*anyopaque, PaneClosure) anyerror!void,
};

pub const RequestClosePaneHandler = struct {
    model: *const client_model.Model,
    gate: PaneOperationGate,
    effects: CloseRequestEffects,

    /// Sends one close request for the active attached pane. The request does
    /// not mutate the model; `pane_exited` is the authoritative transition.
    ///
    /// ```zig
    /// const closure = try handler.execute() orelse return;
    /// ```
    pub fn execute(handler: *RequestClosePaneHandler) !?PaneClosure {
        if (handler.gate.pending(handler.gate.context)) {
            return null;
        }

        const closure = handler.model.planPaneClosure() orelse return null;
        try handler.effects.send(handler.effects.context, closure);

        return closure;
    }
};

pub const PaneExitEffects = struct {
    context: *anyopaque,
    apply: *const fn (*anyopaque, PaneExit) anyerror!void,
};

pub const HandlePaneExitHandler = struct {
    model: *client_model.Model,
    effects: PaneExitEffects,

    /// Commits pane retirement before releasing client resources. Stale exit
    /// traffic still runs idempotent cleanup so pending requests can settle.
    ///
    /// ```zig
    /// const transition = try handler.execute(pane_id);
    /// ```
    pub fn execute(handler: *HandlePaneExitHandler, pane_id: schema.PaneId) !PaneExit {
        const transition = handler.model.retirePane(pane_id);
        try handler.effects.apply(handler.effects.context, transition);

        return transition;
    }
};

const TestingModel = struct {
    model: *client_model.Model,
    location: schema.TabLocation,
    pane_id: schema.PaneId,

    fn init() !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();

        const location: schema.TabLocation = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        };
        const pane_id: schema.PaneId = @enumFromInt(1);
        try model.workspace.bootstrap(pane_id, location, .{ .cols = 40, .rows = 10 });

        return .{ .model = model, .location = location, .pane_id = pane_id };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }
};

const RequestCapture = struct {
    blocked: bool = false,
    calls: usize = 0,
    closure: ?PaneClosure = null,
    fail: bool = false,

    fn gate(capture: *RequestCapture) PaneOperationGate {
        return .{ .context = capture, .pending = pending };
    }

    fn port(capture: *RequestCapture) CloseRequestEffects {
        return .{ .context = capture, .send = send };
    }

    fn pending(context: *anyopaque) bool {
        const capture: *RequestCapture = @ptrCast(@alignCast(context));
        return capture.blocked;
    }

    fn send(context: *anyopaque, closure: PaneClosure) !void {
        const capture: *RequestCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.closure = closure;
        if (capture.fail) {
            return error.SendFailed;
        }
    }
};

const ExitCapture = struct {
    model: *const client_model.Model,
    pane_id: schema.PaneId,
    calls: usize = 0,
    observed_commit: bool = false,
    fail: bool = false,

    fn port(capture: *ExitCapture) PaneExitEffects {
        return .{ .context = capture, .apply = apply };
    }

    fn apply(context: *anyopaque, transition: PaneExit) !void {
        const capture: *ExitCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.observed_commit = capture.model.workspace.activeConst().?.model.findConst(capture.pane_id) == null;
        switch (transition) {
            .retired => |retired| {
                capture.observed_commit = capture.observed_commit and
                    retired.pane_id == capture.pane_id and
                    capture.model.version().panes == 1;
            },
            .stale => |pane_id| {
                capture.observed_commit = capture.observed_commit and pane_id == capture.pane_id;
            },
        }

        if (capture.fail) {
            return error.CleanupFailed;
        }
    }
};

test "RequestClosePaneHandler gates and sends without model mutation" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RequestCapture = .{ .blocked = true };
    var handler: RequestClosePaneHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.port(),
    };

    try std.testing.expect((try handler.execute()) == null);
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    capture.blocked = false;

    const closure = (try handler.execute()).?;

    try std.testing.expectEqual(testing.pane_id, closure.pane_id);
    try std.testing.expectEqualDeep(testing.location, closure.location);
    try std.testing.expectEqualDeep(closure, capture.closure.?);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
    try std.testing.expect(testing.model.workspace.findPane(testing.pane_id) != null);
}

test "RequestClosePaneHandler rejects detached panes before effects" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    testing.model.workspace.findPane(testing.pane_id).?.attached = false;
    var capture: RequestCapture = .{};
    var handler: RequestClosePaneHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.port(),
    };

    try std.testing.expect((try handler.execute()) == null);

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "RequestClosePaneHandler propagates delivery failure without model mutation" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RequestCapture = .{ .fail = true };
    var handler: RequestClosePaneHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.port(),
    };

    try std.testing.expectError(error.SendFailed, handler.execute());

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(testing.model.workspace.findPane(testing.pane_id) != null);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "HandlePaneExitHandler commits before cleanup" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: ExitCapture = .{ .model = testing.model, .pane_id = testing.pane_id };
    var handler: HandlePaneExitHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    const transition = try handler.execute(testing.pane_id);

    try std.testing.expect(transition == .retired);
    try std.testing.expect(transition.retired.active);
    try std.testing.expect(transition.retired.tab_empty);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.observed_commit);
}

test "HandlePaneExitHandler preserves a committed exit after cleanup failure" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: ExitCapture = .{
        .model = testing.model,
        .pane_id = testing.pane_id,
        .fail = true,
    };
    var handler: HandlePaneExitHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    try std.testing.expectError(error.CleanupFailed, handler.execute(testing.pane_id));

    try std.testing.expect(testing.model.workspace.findPane(testing.pane_id) == null);
    try std.testing.expectEqualDeep(client_model.Version{ .panes = 1 }, testing.model.version());
    try std.testing.expect(capture.observed_commit);
}

test "HandlePaneExitHandler applies idempotent cleanup to stale exits" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    _ = testing.model.retirePane(testing.pane_id);
    var capture: ExitCapture = .{ .model = testing.model, .pane_id = testing.pane_id };
    var handler: HandlePaneExitHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };
    const version_before = testing.model.version();

    const transition = try handler.execute(testing.pane_id);

    try std.testing.expect(transition == .stale);
    try std.testing.expectEqual(testing.pane_id, transition.stale);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualDeep(version_before, testing.model.version());
}
