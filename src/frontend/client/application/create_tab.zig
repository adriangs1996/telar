//! Application use cases for requesting and confirming tab creation.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../model.zig");

const schema = core.schema;

pub const RequestTabCreation = struct {
    /// Empty asks the runtime aggregate to generate its canonical label.
    label: []const u8 = "",
};

pub const TabCreationIntent = struct {
    workspace: schema.WorkspaceLocation,
    cwd_source: schema.PaneId,
    /// Borrowed only for the synchronous send callback.
    label: []const u8,
};

pub const TabOperationGate = struct {
    context: *anyopaque,
    pending: *const fn (*anyopaque) bool,
};

pub const CreationRequestEffects = struct {
    context: *anyopaque,
    send: *const fn (*anyopaque, TabCreationIntent) anyerror!void,
};

pub const RequestTabCreationHandler = struct {
    model: *const client_model.Model,
    gate: TabOperationGate,
    effects: CreationRequestEffects,

    /// Plans a tab launch from the attached focused pane and delivers one
    /// intent without changing the semantic model.
    ///
    /// ```zig
    /// if (!try handler.execute(.{})) return;
    /// ```
    pub fn execute(handler: *RequestTabCreationHandler, request: RequestTabCreation) !bool {
        if (handler.gate.pending(handler.gate.context)) {
            return false;
        }

        try validateLabel(request.label);
        const plan = handler.model.planTabCreation() orelse return false;
        const intent: TabCreationIntent = .{
            .workspace = plan.workspace,
            .cwd_source = plan.cwd_source,
            .label = request.label,
        };
        try handler.effects.send(handler.effects.context, intent);

        return true;
    }
};

pub const ConfirmTabCreation = client_model.NewTab;

pub const ConfirmationEffects = struct {
    context: *anyopaque,
    apply: *const fn (*anyopaque, client_model.TabCreation) anyerror!void,
};

pub const ConfirmTabCreationHandler = struct {
    model: *client_model.Model,
    effects: ConfirmationEffects,

    /// Commits the canonical tab before synchronizing client resources.
    /// Model failures have no effects; effect failures preserve the commit.
    ///
    /// ```zig
    /// const creation = try handler.execute(command);
    /// ```
    pub fn execute(handler: *ConfirmTabCreationHandler, command: ConfirmTabCreation) !client_model.TabCreation {
        const creation = try handler.model.createTab(command);
        try handler.effects.apply(handler.effects.context, creation);

        return creation;
    }
};

fn validateLabel(label: []const u8) !void {
    if (label.len > schema.max_tab_label_bytes) {
        return error.InvalidTabLabel;
    }
    if (!std.unicode.utf8ValidateSlice(label)) {
        return error.InvalidUtf8;
    }
    for (label) |byte| {
        if (byte < 0x20 or byte == 0x7f) {
            return error.InvalidTabLabel;
        }
    }
}

const RequestCapture = struct {
    blocked: bool = false,
    fail: bool = false,
    calls: usize = 0,
    workspace: ?schema.WorkspaceLocation = null,
    cwd_source: ?schema.PaneId = null,
    label: [schema.max_tab_label_bytes]u8 = undefined,
    label_len: u8 = 0,

    fn gate(capture: *RequestCapture) TabOperationGate {
        return .{ .context = capture, .pending = pending };
    }

    fn effects(capture: *RequestCapture) CreationRequestEffects {
        return .{ .context = capture, .send = send };
    }

    fn pending(context: *anyopaque) bool {
        const capture: *RequestCapture = @ptrCast(@alignCast(context));
        return capture.blocked;
    }

    fn send(context: *anyopaque, intent: TabCreationIntent) !void {
        const capture: *RequestCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.workspace = intent.workspace;
        capture.cwd_source = intent.cwd_source;
        capture.label_len = @intCast(intent.label.len);
        @memcpy(capture.label[0..intent.label.len], intent.label);

        if (capture.fail) {
            return error.DeliveryFailed;
        }
    }

    fn labelSlice(capture: *const RequestCapture) []const u8 {
        return capture.label[0..capture.label_len];
    }
};

const EffectsCapture = struct {
    model: *const client_model.Model,
    expected: schema.TabLocation,
    calls: usize = 0,
    observed_commit: bool = false,
    fail: bool = false,

    fn port(capture: *EffectsCapture) ConfirmationEffects {
        return .{ .context = capture, .apply = apply };
    }

    fn apply(context: *anyopaque, creation: client_model.TabCreation) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        const version = capture.model.version();
        capture.calls += 1;
        capture.observed_commit = std.meta.eql(capture.model.activeTabLocation(), capture.expected) and
            capture.model.workspace.count == 2 and
            version.tabs == 1 and
            version.active_tab == 1 and
            std.meta.eql(creation.created, capture.expected);

        if (capture.fail) {
            return error.CreationSyncFailed;
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

        return .{ .model = model, .first = first, .second = second };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }

    fn command(testing: *const TestingModel) ConfirmTabCreation {
        return .{
            .created = .{
                .location = testing.second,
                .position = 1,
                .label = "logs",
                .root_pane_id = @enumFromInt(2),
            },
            .size = .{ .cols = 20, .rows = 5 },
        };
    }
};

test "tab creation request sends the current workspace and focused pane without mutation" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RequestCapture = .{};
    var handler: RequestTabCreationHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.effects(),
    };

    try std.testing.expect(try handler.execute(.{ .label = "logs" }));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualDeep(testing.first.workspace, capture.workspace.?);
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(1)), capture.cwd_source.?);
    try std.testing.expectEqualStrings("logs", capture.labelSlice());
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "tab creation request suppresses blocked and absent launch sources" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RequestCapture = .{ .blocked = true };
    var handler: RequestTabCreationHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.effects(),
    };

    try std.testing.expect(!try handler.execute(.{}));
    capture.blocked = false;
    _ = testing.model.departWorkspace();
    try std.testing.expect(!try handler.execute(.{}));

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
}

test "tab creation request rejects invalid labels before delivery" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RequestCapture = .{};
    var handler: RequestTabCreationHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.effects(),
    };
    var too_long: [schema.max_tab_label_bytes + 1]u8 = @splat('a');
    const invalid_utf8 = [_]u8{0xff};

    try std.testing.expectError(error.InvalidTabLabel, handler.execute(.{ .label = &too_long }));
    try std.testing.expectError(error.InvalidTabLabel, handler.execute(.{ .label = "bad\nlabel" }));
    try std.testing.expectError(error.InvalidUtf8, handler.execute(.{ .label = &invalid_utf8 }));

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "tab creation request propagates delivery failure without mutation" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RequestCapture = .{ .fail = true };
    var handler: RequestTabCreationHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.effects(),
    };

    try std.testing.expectError(error.DeliveryFailed, handler.execute(.{}));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "ConfirmTabCreationHandler commits before synchronizing client resources" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var effects: EffectsCapture = .{ .model = testing.model, .expected = testing.second };
    var handler: ConfirmTabCreationHandler = .{
        .model = testing.model,
        .effects = effects.port(),
    };

    const creation = try handler.execute(testing.command());

    try std.testing.expectEqualDeep(testing.first, creation.previous);
    try std.testing.expectEqualDeep(testing.second, creation.created);
    try std.testing.expectEqual(@as(usize, 1), effects.calls);
    try std.testing.expect(effects.observed_commit);
}

test "ConfirmTabCreationHandler rejects model failures before effects" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var effects: EffectsCapture = .{ .model = testing.model, .expected = testing.second };
    var handler: ConfirmTabCreationHandler = .{
        .model = testing.model,
        .effects = effects.port(),
    };
    var command = testing.command();
    command.created.location.workspace = .{ .workspace = @enumFromInt(9) };

    try std.testing.expectError(error.UnexpectedWorkspace, handler.execute(command));

    try std.testing.expectEqual(@as(usize, 0), effects.calls);
    try std.testing.expectEqual(@as(usize, 1), testing.model.workspace.count);
    try std.testing.expectEqualDeep(testing.first, testing.model.activeTabLocation().?);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "ConfirmTabCreationHandler preserves a committed creation after effect failure" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var effects: EffectsCapture = .{
        .model = testing.model,
        .expected = testing.second,
        .fail = true,
    };
    var handler: ConfirmTabCreationHandler = .{
        .model = testing.model,
        .effects = effects.port(),
    };

    try std.testing.expectError(error.CreationSyncFailed, handler.execute(testing.command()));

    try std.testing.expectEqualDeep(testing.second, testing.model.activeTabLocation().?);
    try std.testing.expectEqual(@as(usize, 2), testing.model.workspace.count);
    try std.testing.expectEqual(@as(u64, 1), testing.model.version().tabs);
    try std.testing.expectEqual(@as(u64, 1), testing.model.version().active_tab);
    try std.testing.expect(effects.observed_commit);
}
