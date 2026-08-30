//! Application use case for requesting one tab rename.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../model.zig");

const schema = core.schema;

pub const RequestRenameTab = struct {
    tab_id: schema.TabId,
    label: []const u8,
};

pub const RequestedRename = struct {
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
    send: *const fn (*anyopaque, RequestedRename) anyerror!void,
};

pub const RequestRenameTabHandler = struct {
    model: *const client_model.Model,
    gate: TabOperationGate,
    effects: RenameRequestEffects,

    /// Resolves the prompt's tab identity and sends its rename intent.
    /// Pending operations and vanished targets return null without effects.
    ///
    /// ```zig
    /// const location = try handler.execute(command) orelse return;
    /// ```
    pub fn execute(handler: *RequestRenameTabHandler, command: RequestRenameTab) !?schema.TabLocation {
        if (handler.gate.pending(handler.gate.context)) {
            return null;
        }

        const location = handler.model.tabLocation(command.tab_id) orelse return null;
        try handler.effects.send(handler.effects.context, .{
            .location = location,
            .label = command.label,
        });

        return location;
    }
};

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

    fn send(context: *anyopaque, requested: RequestedRename) !void {
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

test "RequestRenameTabHandler resolves an inactive target without mutating the model" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RequestCapture = .{};
    var handler: RequestRenameTabHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.effects(),
    };

    const location = (try handler.execute(.{
        .tab_id = testing.second.tab_id,
        .label = "server",
    })).?;

    try std.testing.expectEqualDeep(testing.second, location);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualDeep(testing.second, capture.location.?);
    try std.testing.expectEqualStrings("server", capture.labelSlice());
    try std.testing.expectEqualStrings("logs", testing.model.workspace.find(testing.second.tab_id).?.labelSlice());
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "RequestRenameTabHandler suppresses blocked and missing requests" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RequestCapture = .{ .blocked = true };
    var handler: RequestRenameTabHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.effects(),
    };

    try std.testing.expect((try handler.execute(.{
        .tab_id = testing.second.tab_id,
        .label = "blocked",
    })) == null);
    capture.blocked = false;
    try std.testing.expect((try handler.execute(.{
        .tab_id = @enumFromInt(9),
        .label = "missing",
    })) == null);

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "RequestRenameTabHandler propagates delivery failure without mutation" {
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
