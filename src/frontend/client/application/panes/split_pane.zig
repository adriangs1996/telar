//! Application use cases for requesting, confirming and recovering one pane split.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../model/root.zig");

const schema = core.schema;
const ui = core.ui;

pub const PaneSplit = client_model.PaneSplit;
pub const PaneSplitPlan = client_model.PaneSplitPlan;

pub const PaneOperationGate = struct {
    context: *anyopaque,
    pending: *const fn (*anyopaque) bool,
};

pub const RequestEffects = struct {
    context: *anyopaque,
    resize: *const fn (*anyopaque, client_model.PaneResize) anyerror!void,
    send: *const fn (*anyopaque, client_model.PaneSplitPlan) anyerror!void,
};

pub const RequestPaneSplitHandler = struct {
    model: *client_model.Model,
    gate: PaneOperationGate,
    effects: RequestEffects,

    /// Plans and provisionally resizes one split before sending it. Any local
    /// delivery failure restores the exact pre-request size.
    ///
    /// ```zig
    /// const plan = try handler.execute(.{ .axis = .horizontal, .area = area });
    /// ```
    pub fn execute(handler: *RequestPaneSplitHandler, request: client_model.RequestPaneSplit) !?PaneSplitPlan {
        if (handler.gate.pending(handler.gate.context)) {
            return null;
        }

        const plan = handler.model.planPaneSplit(request) orelse return null;
        handler.effects.resize(handler.effects.context, plan.provisional_resize) catch |err| {
            try handler.effects.resize(handler.effects.context, plan.restore_resize);
            return err;
        };
        handler.effects.send(handler.effects.context, plan) catch |err| {
            try handler.effects.resize(handler.effects.context, plan.restore_resize);
            return err;
        };

        return plan;
    }
};

pub const ConfirmPaneSplit = struct {
    requested: PaneSplit,
    confirmed_pane: schema.PaneId,
    confirmed_location: schema.TabLocation,
    created: bool,
};

pub const ConfirmationEffects = struct {
    context: *anyopaque,
    deliver: *const fn (*anyopaque, client_model.PaneSplitCommit) anyerror!void,
};

pub const ConfirmPaneSplitHandler = struct {
    model: *client_model.Model,
    effects: ConfirmationEffects,

    /// Validates the exact runtime reply, commits the passive model and only
    /// then synchronizes client resources.
    ///
    /// ```zig
    /// const commit = try handler.execute(command);
    /// ```
    pub fn execute(handler: *ConfirmPaneSplitHandler, command: ConfirmPaneSplit) !client_model.PaneSplitCommit {
        if (!command.created or
            command.confirmed_pane == command.requested.target_pane or
            !std.meta.eql(command.confirmed_location, command.requested.location))
        {
            return error.UnexpectedPane;
        }

        const commit = try handler.model.commitPaneSplit(.{
            .split = command.requested,
            .new_pane = command.confirmed_pane,
        });
        try handler.effects.deliver(handler.effects.context, commit);

        return commit;
    }
};

pub const RecoveryStatus = enum {
    restored,
    not_required,
    stale,
};

pub const RecoveryEffects = struct {
    context: *anyopaque,
    resize: *const fn (*anyopaque, client_model.PaneResize) anyerror!void,
};

pub const RecoverPaneSplitHandler = struct {
    model: *client_model.Model,
    area: ui.Rect,
    effects: RecoveryEffects,

    /// Restores only the exact active target that was provisionally resized.
    /// Inactive targets need no resize; retired state is reported as stale.
    ///
    /// ```zig
    /// const status = try handler.execute(split);
    /// ```
    pub fn execute(handler: *RecoverPaneSplitHandler, split: PaneSplit) !RecoveryStatus {
        return switch (handler.model.recoverPaneSplit(.{ .split = split, .area = handler.area })) {
            .resize => |resize| recovery: {
                try handler.effects.resize(handler.effects.context, resize);
                break :recovery .restored;
            },
            .not_required => .not_required,
            .stale => .stale,
        };
    }
};

const TestingModel = struct {
    model: *client_model.Model,
    location: schema.TabLocation,
    pane_id: schema.PaneId,
    area: ui.Rect = .{ .w = 40, .h = 10 },

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
        try model.workspace.bootstrap(.{ .pane_id = pane_id, .location = location, .size = .{ .cols = 40, .rows = 10 } });
        model.workspace.active().?.model.setCellSize(8, 16);

        return .{ .model = model, .location = location, .pane_id = pane_id };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }

    fn split(testing: *const TestingModel) PaneSplit {
        return .{
            .target_pane = testing.pane_id,
            .location = testing.location,
            .axis = .horizontal,
            .area = testing.area,
        };
    }
};

const RequestStep = enum {
    resize,
    send,
};

const RequestCapture = struct {
    blocked: bool = false,
    send_failure: ?anyerror = null,
    steps: [3]RequestStep = undefined,
    step_count: u8 = 0,
    resizes: [2]client_model.PaneResize = undefined,
    resize_count: u8 = 0,

    fn gate(capture: *RequestCapture) PaneOperationGate {
        return .{ .context = capture, .pending = pending };
    }

    fn port(capture: *RequestCapture) RequestEffects {
        return .{ .context = capture, .resize = resize, .send = send };
    }

    fn pending(context: *anyopaque) bool {
        const capture: *RequestCapture = @ptrCast(@alignCast(context));
        return capture.blocked;
    }

    fn resize(context: *anyopaque, value: client_model.PaneResize) !void {
        const capture: *RequestCapture = @ptrCast(@alignCast(context));
        capture.steps[capture.step_count] = .resize;
        capture.step_count += 1;
        capture.resizes[capture.resize_count] = value;
        capture.resize_count += 1;
    }

    fn send(context: *anyopaque, _: client_model.PaneSplitPlan) !void {
        const capture: *RequestCapture = @ptrCast(@alignCast(context));
        capture.steps[capture.step_count] = .send;
        capture.step_count += 1;
        if (capture.send_failure) |failure| {
            return failure;
        }
    }

    fn recorded(capture: *const RequestCapture) []const RequestStep {
        return capture.steps[0..capture.step_count];
    }
};

const ConfirmationCapture = struct {
    model: *const client_model.Model,
    pane_id: schema.PaneId,
    calls: usize = 0,
    observed_commit: bool = false,
    fail: bool = false,

    fn port(capture: *ConfirmationCapture) ConfirmationEffects {
        return .{ .context = capture, .deliver = deliver };
    }

    fn deliver(context: *anyopaque, commit: client_model.PaneSplitCommit) !void {
        const capture: *ConfirmationCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.observed_commit = capture.model.workspace.activeConst().?.model.findConst(capture.pane_id) != null and
            capture.model.version().panes == commit.panes_revision and
            commit.pane_id == capture.pane_id;
        if (capture.fail) {
            return error.SyncFailed;
        }
    }
};

const RecoveryCapture = struct {
    calls: usize = 0,
    resize_value: ?client_model.PaneResize = null,
    fail: bool = false,

    fn port(capture: *RecoveryCapture) RecoveryEffects {
        return .{ .context = capture, .resize = resize };
    }

    fn resize(context: *anyopaque, value: client_model.PaneResize) !void {
        const capture: *RecoveryCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.resize_value = value;
        if (capture.fail) {
            return error.ResizeFailed;
        }
    }
};

test "RequestPaneSplitHandler gates and plans without model mutation" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RequestCapture = .{ .blocked = true };
    var handler: RequestPaneSplitHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.port(),
    };

    try std.testing.expect((try handler.execute(.{ .axis = .horizontal, .area = testing.area })) == null);
    try std.testing.expectEqual(@as(usize, 0), capture.recorded().len);
    capture.blocked = false;

    const plan = (try handler.execute(.{ .axis = .horizontal, .area = testing.area })).?;

    try std.testing.expectEqualSlices(RequestStep, &.{ .resize, .send }, capture.recorded());
    try std.testing.expectEqual(testing.pane_id, plan.split.target_pane);
    try std.testing.expectEqualDeep(testing.area, plan.split.area);
    try std.testing.expectEqual(@as(u16, 8), plan.new_pane_size.cell_width_px);
    try std.testing.expectEqual(@as(u16, 16), plan.new_pane_size.cell_height_px);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
    try std.testing.expectEqual(@as(usize, 1), testing.model.workspace.active().?.model.pane_count);
}

test "RequestPaneSplitHandler restores the pre-request size after send failure" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RequestCapture = .{ .send_failure = error.SendFailed };
    var handler: RequestPaneSplitHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.port(),
    };

    try std.testing.expectError(error.SendFailed, handler.execute(.{ .axis = .horizontal, .area = testing.area }));

    try std.testing.expectEqualSlices(RequestStep, &.{ .resize, .send, .resize }, capture.recorded());
    try std.testing.expectEqual(testing.pane_id, capture.resizes[1].pane_id);
    try std.testing.expectEqual(@as(u16, testing.area.w), capture.resizes[1].size.cols);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "ConfirmPaneSplitHandler validates and commits before effects" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const new_pane: schema.PaneId = @enumFromInt(2);
    var capture: ConfirmationCapture = .{ .model = testing.model, .pane_id = new_pane };
    var handler: ConfirmPaneSplitHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    try std.testing.expectError(error.UnexpectedPane, handler.execute(.{
        .requested = testing.split(),
        .confirmed_pane = new_pane,
        .confirmed_location = testing.location,
        .created = false,
    }));
    try std.testing.expectEqual(@as(usize, 0), capture.calls);

    const commit = try handler.execute(.{
        .requested = testing.split(),
        .confirmed_pane = new_pane,
        .confirmed_location = testing.location,
        .created = true,
    });

    try std.testing.expectEqual(client_model.PaneSplitDisposition.active, commit.disposition);
    try std.testing.expectEqual(client_model.Change.changed, commit.change);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.observed_commit);
}

test "ConfirmPaneSplitHandler preserves the commit after effect failure" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const new_pane: schema.PaneId = @enumFromInt(2);
    var capture: ConfirmationCapture = .{
        .model = testing.model,
        .pane_id = new_pane,
        .fail = true,
    };
    var handler: ConfirmPaneSplitHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    try std.testing.expectError(error.SyncFailed, handler.execute(.{
        .requested = testing.split(),
        .confirmed_pane = new_pane,
        .confirmed_location = testing.location,
        .created = true,
    }));

    try std.testing.expect(testing.model.workspace.findPane(new_pane) != null);
    try std.testing.expectEqual(@as(u64, 1), testing.model.version().panes);
    try std.testing.expect(capture.observed_commit);
}

test "RecoverPaneSplitHandler restores only the current active target" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RecoveryCapture = .{};
    var handler: RecoverPaneSplitHandler = .{
        .model = testing.model,
        .area = testing.area,
        .effects = capture.port(),
    };

    try std.testing.expectEqual(RecoveryStatus.restored, try handler.execute(testing.split()));
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(testing.pane_id, capture.resize_value.?.pane_id);

    _ = testing.model.workspace.active().?.model.removePane(testing.pane_id);
    try std.testing.expectEqual(RecoveryStatus.stale, try handler.execute(testing.split()));
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}

test "RecoverPaneSplitHandler propagates resize failure without model mutation" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RecoveryCapture = .{ .fail = true };
    var handler: RecoverPaneSplitHandler = .{
        .model = testing.model,
        .area = testing.area,
        .effects = capture.port(),
    };

    try std.testing.expectError(error.ResizeFailed, handler.execute(testing.split()));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}
