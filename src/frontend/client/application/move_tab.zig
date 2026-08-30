//! Application use cases for requesting and confirming a tab move.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../model.zig");

const schema = core.schema;

pub const RequestTabMove = struct {
    direction: schema.TabMoveDirection,
};

pub const TabMoveIntent = struct {
    location: schema.TabLocation,
    direction: schema.TabMoveDirection,
};

pub const TabOperationGate = struct {
    context: *anyopaque,
    pending: *const fn (*anyopaque) bool,
};

pub const MoveRequestEffects = struct {
    context: *anyopaque,
    send: *const fn (*anyopaque, TabMoveIntent) anyerror!void,
};

pub const RequestTabMoveHandler = struct {
    model: *const client_model.Model,
    gate: TabOperationGate,
    effects: MoveRequestEffects,

    /// Sends one move intent for the active tab without changing its local
    /// position. Blocked requests and an empty projection have no effects.
    ///
    /// ```zig
    /// if (!try handler.execute(.{ .direction = .previous })) {
    ///     return;
    /// }
    /// ```
    pub fn execute(handler: *RequestTabMoveHandler, request: RequestTabMove) !bool {
        if (handler.gate.pending(handler.gate.context)) {
            return false;
        }

        const location = handler.model.activeTabLocation() orelse return false;
        try handler.effects.send(handler.effects.context, .{
            .location = location,
            .direction = request.direction,
        });

        return true;
    }
};

pub const ConfirmTabMove = struct {
    location: schema.TabLocation,
    position: u16,
};

pub const ConfirmTabMoveHandler = struct {
    model: *client_model.Model,

    /// Commits the canonical runtime position. A repeated position is a
    /// semantic no-op and leaves the model version unchanged.
    ///
    /// ```zig
    /// const change = try handler.execute(command);
    /// ```
    pub fn execute(handler: *ConfirmTabMoveHandler, command: ConfirmTabMove) !client_model.Change {
        return handler.model.applyTabPosition(command.location, command.position);
    }
};

const RequestCapture = struct {
    blocked: bool = false,
    fail: bool = false,
    calls: usize = 0,
    intent: ?TabMoveIntent = null,

    fn gate(capture: *RequestCapture) TabOperationGate {
        return .{ .context = capture, .pending = pending };
    }

    fn effects(capture: *RequestCapture) MoveRequestEffects {
        return .{ .context = capture, .send = send };
    }

    fn pending(context: *anyopaque) bool {
        const capture: *RequestCapture = @ptrCast(@alignCast(context));
        return capture.blocked;
    }

    fn send(context: *anyopaque, intent: TabMoveIntent) !void {
        const capture: *RequestCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.intent = intent;

        if (capture.fail) {
            return error.DeliveryFailed;
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
        _ = model.workspace.select(second.tab_id);

        return .{ .model = model, .first = first, .second = second };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }
};

test "tab move request sends the active identity without provisional mutation" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RequestCapture = .{};
    var handler: RequestTabMoveHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.effects(),
    };

    try std.testing.expect(try handler.execute(.{ .direction = .previous }));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualDeep(TabMoveIntent{
        .location = testing.second,
        .direction = .previous,
    }, capture.intent.?);
    try std.testing.expectEqual(@as(?usize, 1), testing.model.workspace.indexOf(testing.second.tab_id));
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "tab move request suppresses blocked and absent targets" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RequestCapture = .{ .blocked = true };
    var handler: RequestTabMoveHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.effects(),
    };

    try std.testing.expect(!try handler.execute(.{ .direction = .next }));
    capture.blocked = false;
    _ = testing.model.departWorkspace();
    try std.testing.expect(!try handler.execute(.{ .direction = .next }));

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
}

test "tab move request propagates delivery failure without mutation" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RequestCapture = .{ .fail = true };
    var handler: RequestTabMoveHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.effects(),
    };

    try std.testing.expectError(error.DeliveryFailed, handler.execute(.{ .direction = .next }));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(@as(?usize, 1), testing.model.workspace.indexOf(testing.second.tab_id));
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "tab move confirmation commits the canonical position and preserves active identity" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var handler: ConfirmTabMoveHandler = .{ .model = testing.model };

    const change = try handler.execute(.{ .location = testing.second, .position = 0 });

    try std.testing.expectEqual(client_model.Change.changed, change);
    try std.testing.expectEqual(@as(?usize, 0), testing.model.workspace.indexOf(testing.second.tab_id));
    try std.testing.expectEqualDeep(testing.second, testing.model.activeTabLocation().?);
    try std.testing.expectEqual(@as(u64, 1), testing.model.version().tabs);
    try std.testing.expectEqual(@as(u64, 0), testing.model.version().active_tab);
}

test "tab move confirmation preserves the version for a canonical no-op" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var handler: ConfirmTabMoveHandler = .{ .model = testing.model };

    const change = try handler.execute(.{ .location = testing.second, .position = 1 });

    try std.testing.expectEqual(client_model.Change.unchanged, change);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "tab move confirmation rejects invalid canonical state without mutation" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var handler: ConfirmTabMoveHandler = .{ .model = testing.model };
    const other_workspace: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(9) },
        .tab_id = testing.second.tab_id,
    };
    const missing_tab: schema.TabLocation = .{
        .workspace = testing.first.workspace,
        .tab_id = @enumFromInt(9),
    };

    try std.testing.expectError(error.UnexpectedWorkspace, handler.execute(.{
        .location = other_workspace,
        .position = 0,
    }));
    try std.testing.expectError(error.TabNotFound, handler.execute(.{
        .location = missing_tab,
        .position = 0,
    }));
    try std.testing.expectError(error.InvalidTabPosition, handler.execute(.{
        .location = testing.second,
        .position = 2,
    }));

    try std.testing.expectEqual(@as(?usize, 1), testing.model.workspace.indexOf(testing.second.tab_id));
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}
