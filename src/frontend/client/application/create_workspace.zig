//! Application use cases for requesting and confirming workspace creation.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../model.zig");

const schema = core.schema;

pub const RequestWorkspaceCreation = struct {
    /// Borrowed only for the synchronous request.
    name: []const u8,
};

pub const WorkspaceCreation = struct {
    /// Borrowed only for the synchronous send callback.
    name: []const u8,
    cwd_source: schema.PaneId,
};

pub const WorkspaceOperationGate = struct {
    context: *anyopaque,
    pending: *const fn (*anyopaque) bool,
};

pub const CreationRequestEffects = struct {
    context: *anyopaque,
    send: *const fn (*anyopaque, WorkspaceCreation) anyerror!void,
};

pub const RequestWorkspaceCreationHandler = struct {
    model: *const client_model.Model,
    gate: WorkspaceOperationGate,
    effects: CreationRequestEffects,

    /// Sends one creation intent from the attached focused pane. A blocked or
    /// stale request returns false without effects or semantic mutation.
    ///
    /// ```zig
    /// if (!try handler.execute(.{ .name = "agents" })) return;
    /// ```
    pub fn execute(handler: *RequestWorkspaceCreationHandler, command: RequestWorkspaceCreation) !bool {
        if (handler.gate.pending(handler.gate.context)) {
            return false;
        }

        try validateName(command.name);
        const cwd_source = handler.model.planWorkspaceCreation() orelse return false;
        try handler.effects.send(handler.effects.context, .{
            .name = command.name,
            .cwd_source = cwd_source,
        });

        return true;
    }
};

pub const ConfirmWorkspaceCreation = struct {
    created: bool,
    arrival: client_model.WorkspaceArrival,
};

pub const WorkspaceCreationEffects = struct {
    context: *anyopaque,
    apply: *const fn (*anyopaque, *const client_model.WorkspaceReplacement) anyerror!void,
};

pub const ConfirmWorkspaceCreationHandler = struct {
    model: *client_model.Model,
    effects: WorkspaceCreationEffects,

    /// Replaces the current projection in one commit before synchronizing
    /// client resources. Effect failure never restores the retired workspace.
    ///
    /// ```zig
    /// const replacement = try handler.execute(command);
    /// ```
    pub fn execute(handler: *ConfirmWorkspaceCreationHandler, command: ConfirmWorkspaceCreation) !client_model.WorkspaceReplacement {
        if (!command.created) {
            return error.UnexpectedRequest;
        }

        const replacement = try handler.model.replaceWorkspace(command.arrival);
        try handler.effects.apply(handler.effects.context, &replacement);

        return replacement;
    }
};

fn validateName(name: []const u8) !void {
    if (name.len == 0 or name.len > schema.max_tab_label_bytes) {
        return error.InvalidWorkspaceName;
    }
    if (!std.unicode.utf8ValidateSlice(name)) {
        return error.InvalidUtf8;
    }
    for (name) |byte| {
        if (byte < 0x20 or byte == 0x7f) {
            return error.InvalidWorkspaceName;
        }
    }
}

const TestingModel = struct {
    model: *client_model.Model,
    location: schema.TabLocation,

    fn init() !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();

        const location: schema.TabLocation = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        };
        try model.workspace.bootstrap(@enumFromInt(1), location, .{ .cols = 20, .rows = 5 });

        return .{ .model = model, .location = location };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }

    fn arrival(testing: *const TestingModel) client_model.WorkspaceArrival {
        _ = testing;

        return .{
            .pane_id = @enumFromInt(2),
            .location = .{
                .workspace = .{ .workspace = @enumFromInt(2) },
                .tab_id = @enumFromInt(2),
            },
            .size = .{ .cols = 30, .rows = 8 },
        };
    }
};

const RequestCapture = struct {
    blocked: bool = false,
    fail: bool = false,
    calls: usize = 0,
    source: ?schema.PaneId = null,
    name: [schema.max_tab_label_bytes]u8 = undefined,
    name_len: u8 = 0,

    fn gate(capture: *RequestCapture) WorkspaceOperationGate {
        return .{ .context = capture, .pending = pending };
    }

    fn effects(capture: *RequestCapture) CreationRequestEffects {
        return .{ .context = capture, .send = send };
    }

    fn pending(context: *anyopaque) bool {
        const capture: *RequestCapture = @ptrCast(@alignCast(context));
        return capture.blocked;
    }

    fn send(context: *anyopaque, creation: WorkspaceCreation) !void {
        const capture: *RequestCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.source = creation.cwd_source;
        capture.name_len = @intCast(creation.name.len);
        @memcpy(capture.name[0..creation.name.len], creation.name);

        if (capture.fail) {
            return error.DeliveryFailed;
        }
    }

    fn nameSlice(capture: *const RequestCapture) []const u8 {
        return capture.name[0..capture.name_len];
    }
};

const ConfirmationCapture = struct {
    model: *const client_model.Model,
    expected: schema.TabLocation,
    calls: usize = 0,
    observed_commit: bool = false,
    fail: bool = false,

    fn effects(capture: *ConfirmationCapture) WorkspaceCreationEffects {
        return .{ .context = capture, .apply = apply };
    }

    fn apply(context: *anyopaque, replacement: *const client_model.WorkspaceReplacement) !void {
        const capture: *ConfirmationCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.observed_commit = std.meta.eql(capture.model.activeTabLocation(), capture.expected) and
            std.meta.eql(replacement.location, capture.expected) and
            replacement.departure.source != null and
            capture.model.version().workspace == 1;

        if (capture.fail) {
            return error.CreationSyncFailed;
        }
    }
};

test "workspace creation request sends the focused attached pane without mutation" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RequestCapture = .{};
    var handler: RequestWorkspaceCreationHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.effects(),
    };

    try std.testing.expect(try handler.execute(.{ .name = "agents" }));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(1)), capture.source.?);
    try std.testing.expectEqualStrings("agents", capture.nameSlice());
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "workspace creation request suppresses blocked and absent sources" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RequestCapture = .{ .blocked = true };
    var handler: RequestWorkspaceCreationHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.effects(),
    };

    try std.testing.expect(!try handler.execute(.{ .name = "blocked" }));
    capture.blocked = false;
    _ = testing.model.departWorkspace();
    try std.testing.expect(!try handler.execute(.{ .name = "absent" }));

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
}

test "workspace creation request rejects invalid names before delivery" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RequestCapture = .{};
    var handler: RequestWorkspaceCreationHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.effects(),
    };
    var too_long: [schema.max_tab_label_bytes + 1]u8 = @splat('a');
    const invalid_utf8 = [_]u8{0xff};

    try std.testing.expectError(error.InvalidWorkspaceName, handler.execute(.{ .name = "" }));
    try std.testing.expectError(error.InvalidWorkspaceName, handler.execute(.{ .name = &too_long }));
    try std.testing.expectError(error.InvalidWorkspaceName, handler.execute(.{ .name = "bad\nname" }));
    try std.testing.expectError(error.InvalidUtf8, handler.execute(.{ .name = &invalid_utf8 }));

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "workspace creation request propagates delivery failure without mutation" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RequestCapture = .{ .fail = true };
    var handler: RequestWorkspaceCreationHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.effects(),
    };

    try std.testing.expectError(error.DeliveryFailed, handler.execute(.{ .name = "agents" }));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "workspace creation confirmation replaces the projection before effects" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const arrival = testing.arrival();
    var capture: ConfirmationCapture = .{
        .model = testing.model,
        .expected = arrival.location,
    };
    var handler: ConfirmWorkspaceCreationHandler = .{
        .model = testing.model,
        .effects = capture.effects(),
    };

    const replacement = try handler.execute(.{ .created = true, .arrival = arrival });

    try std.testing.expectEqualDeep(arrival.location, replacement.location);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.observed_commit);
}

test "workspace creation confirmation rejects an uncreated response before mutation" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const arrival = testing.arrival();
    var capture: ConfirmationCapture = .{
        .model = testing.model,
        .expected = arrival.location,
    };
    var handler: ConfirmWorkspaceCreationHandler = .{
        .model = testing.model,
        .effects = capture.effects(),
    };

    try std.testing.expectError(error.UnexpectedRequest, handler.execute(.{
        .created = false,
        .arrival = arrival,
    }));

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expectEqualDeep(testing.location, testing.model.activeTabLocation().?);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "workspace creation confirmation rejects model failures before effects" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var arrival = testing.arrival();
    arrival.location.workspace = testing.location.workspace;
    var capture: ConfirmationCapture = .{
        .model = testing.model,
        .expected = arrival.location,
    };
    var handler: ConfirmWorkspaceCreationHandler = .{
        .model = testing.model,
        .effects = capture.effects(),
    };

    try std.testing.expectError(error.WorkspaceAlreadyActive, handler.execute(.{
        .created = true,
        .arrival = arrival,
    }));

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expectEqualDeep(testing.location, testing.model.activeTabLocation().?);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "workspace creation confirmation preserves its commit after effect failure" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const arrival = testing.arrival();
    var capture: ConfirmationCapture = .{
        .model = testing.model,
        .expected = arrival.location,
        .fail = true,
    };
    var handler: ConfirmWorkspaceCreationHandler = .{
        .model = testing.model,
        .effects = capture.effects(),
    };

    try std.testing.expectError(error.CreationSyncFailed, handler.execute(.{
        .created = true,
        .arrival = arrival,
    }));

    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqualDeep(arrival.location, testing.model.activeTabLocation().?);
    try std.testing.expectEqual(@as(u64, 1), testing.model.version().workspace);
}
