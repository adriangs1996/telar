//! Application use cases for requesting and confirming a tab rename.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../model/root.zig");

const schema = core.schema;

pub const RequestRenameTab = struct {
    tab_id: schema.TabId,
    label: []const u8,
};

pub const TabRenameIntent = struct {
    location: schema.TabLocation,
    /// Borrowed only for the synchronous send callback.
    label: []const u8,
};

pub const TabOperationGate = struct {
    context: *anyopaque,
    pending: *const fn (*anyopaque) bool,
};

pub const RenameRequestEffects = struct {
    context: *anyopaque,
    send: *const fn (*anyopaque, TabRenameIntent) anyerror!void,
};

pub const RequestRenameTabHandler = struct {
    model: *const client_model.Model,
    gate: TabOperationGate,
    effects: RenameRequestEffects,

    /// Validates the label, resolves the prompt's tab identity and sends one
    /// rename intent. Blocked or vanished targets return false without effects.
    ///
    /// ```zig
    /// if (!try handler.execute(command)) {
    ///     return;
    /// }
    /// ```
    pub fn execute(handler: *RequestRenameTabHandler, command: RequestRenameTab) !bool {
        if (handler.gate.pending(handler.gate.context)) {
            return false;
        }

        try validateLabel(command.label);
        const location = handler.model.tabLocation(command.tab_id) orelse return false;
        try handler.effects.send(handler.effects.context, .{
            .location = location,
            .label = command.label,
        });

        return true;
    }
};

pub const ConfirmTabRename = client_model.RenameTab;

pub const ConfirmTabRenameHandler = struct {
    model: *client_model.Model,

    /// Commits the canonical runtime label. Repeating the current label leaves
    /// the model version unchanged.
    ///
    /// ```zig
    /// const change = try handler.execute(command);
    /// ```
    pub fn execute(handler: *ConfirmTabRenameHandler, command: ConfirmTabRename) !client_model.Change {
        return handler.model.renameTab(command);
    }
};

fn validateLabel(label: []const u8) !void {
    if (label.len == 0 or label.len > schema.max_tab_label_bytes) {
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
    failure: ?anyerror = null,
    calls: usize = 0,
    location: ?schema.TabLocation = null,
    label: [schema.max_tab_label_bytes]u8 = undefined,
    label_len: u8 = 0,

    fn gate(capture: *RequestCapture) TabOperationGate {
        return .{ .context = capture, .pending = pending };
    }

    fn effects(capture: *RequestCapture) RenameRequestEffects {
        return .{ .context = capture, .send = send };
    }

    fn pending(context: *anyopaque) bool {
        const capture: *RequestCapture = @ptrCast(@alignCast(context));
        return capture.blocked;
    }

    fn send(context: *anyopaque, requested: TabRenameIntent) !void {
        const capture: *RequestCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.location = requested.location;
        capture.label_len = @intCast(requested.label.len);
        @memcpy(capture.label[0..requested.label.len], requested.label);

        if (capture.failure) |failure| {
            return failure;
        }
    }

    fn labelSlice(capture: *const RequestCapture) []const u8 {
        return capture.label[0..capture.label_len];
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

test "tab rename request resolves an inactive target without mutation" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RequestCapture = .{};
    var handler: RequestRenameTabHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.effects(),
    };

    try std.testing.expect(try handler.execute(.{
        .tab_id = testing.second.tab_id,
        .label = "server",
    }));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualDeep(testing.second, capture.location.?);
    try std.testing.expectEqualStrings("server", capture.labelSlice());
    try std.testing.expectEqualStrings("logs", testing.model.workspace.find(testing.second.tab_id).?.labelSlice());
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "tab rename request suppresses blocked and missing targets" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RequestCapture = .{ .blocked = true };
    var handler: RequestRenameTabHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.effects(),
    };

    try std.testing.expect(!try handler.execute(.{
        .tab_id = testing.second.tab_id,
        .label = "blocked",
    }));
    capture.blocked = false;
    try std.testing.expect(!try handler.execute(.{
        .tab_id = @enumFromInt(9),
        .label = "missing",
    }));

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "tab rename request rejects invalid labels before delivery" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RequestCapture = .{};
    var handler: RequestRenameTabHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.effects(),
    };
    const invalid_utf8 = [_]u8{0xff};
    const too_long = [_]u8{'x'} ** (schema.max_tab_label_bytes + 1);

    try std.testing.expectError(error.InvalidTabLabel, handler.execute(.{
        .tab_id = testing.first.tab_id,
        .label = "",
    }));
    try std.testing.expectError(error.InvalidTabLabel, handler.execute(.{
        .tab_id = testing.first.tab_id,
        .label = "bad\nlabel",
    }));
    try std.testing.expectError(error.InvalidTabLabel, handler.execute(.{
        .tab_id = testing.first.tab_id,
        .label = &too_long,
    }));
    try std.testing.expectError(error.InvalidUtf8, handler.execute(.{
        .tab_id = testing.first.tab_id,
        .label = &invalid_utf8,
    }));

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "tab rename request propagates delivery failure without mutation" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RequestCapture = .{ .failure = error.DeliveryFailed };
    var handler: RequestRenameTabHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.effects(),
    };

    try std.testing.expectError(error.DeliveryFailed, handler.execute(.{
        .tab_id = testing.first.tab_id,
        .label = "server",
    }));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualStrings("main", testing.model.workspace.find(testing.first.tab_id).?.labelSlice());
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "tab rename confirmation commits the canonical label without changing active identity" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var handler: ConfirmTabRenameHandler = .{ .model = testing.model };

    const change = try handler.execute(.{
        .location = testing.second,
        .label = "canonical",
    });

    try std.testing.expectEqual(client_model.Change.changed, change);
    try std.testing.expectEqualStrings("canonical", testing.model.workspace.find(testing.second.tab_id).?.labelSlice());
    try std.testing.expectEqualDeep(testing.first, testing.model.activeTabLocation().?);
    try std.testing.expectEqual(@as(u64, 1), testing.model.version().tabs);
    try std.testing.expectEqual(@as(u64, 0), testing.model.version().active_tab);
}

test "tab rename confirmation preserves the version for a canonical no-op" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var handler: ConfirmTabRenameHandler = .{ .model = testing.model };

    const change = try handler.execute(.{
        .location = testing.second,
        .label = "logs",
    });

    try std.testing.expectEqual(client_model.Change.unchanged, change);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "tab rename confirmation rejects invalid canonical state without mutation" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var handler: ConfirmTabRenameHandler = .{ .model = testing.model };
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
        .label = "canonical",
    }));
    try std.testing.expectError(error.TabNotFound, handler.execute(.{
        .location = missing_tab,
        .label = "canonical",
    }));
    try std.testing.expectError(error.InvalidTabLabel, handler.execute(.{
        .location = testing.second,
        .label = "",
    }));

    try std.testing.expectEqualStrings("logs", testing.model.workspace.find(testing.second.tab_id).?.labelSlice());
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}
