//! Application use case for requesting one workspace rename.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../model/root.zig");

const schema = core.schema;

pub const RequestRenameWorkspace = struct {
    workspace: schema.WorkspaceLocation,
    name: []const u8,
};

pub const RequestedRename = struct {
    workspace: schema.WorkspaceLocation,
    /// Borrowed only for the synchronous send callback.
    name: []const u8,
};

pub const WorkspaceOperationGate = struct {
    context: *anyopaque,
    pending: *const fn (*anyopaque) bool,
};

pub const RenameRequestEffects = struct {
    context: *anyopaque,
    send: *const fn (*anyopaque, RequestedRename) anyerror!void,
};

pub const RequestRenameWorkspaceHandler = struct {
    model: *const client_model.Model,
    gate: WorkspaceOperationGate,
    effects: RenameRequestEffects,

    /// Validates the prompt target and sends one rename intent. Pending
    /// operations and stale workspace targets return false without effects.
    ///
    /// ```zig
    /// if (!try handler.execute(command)) return;
    /// ```
    pub fn execute(handler: *RequestRenameWorkspaceHandler, command: RequestRenameWorkspace) !bool {
        if (handler.gate.pending(handler.gate.context)) {
            return false;
        }

        const current = handler.model.workspaceLocation() orelse return false;
        if (!std.meta.eql(current, command.workspace)) {
            return false;
        }

        try handler.effects.send(handler.effects.context, .{
            .workspace = command.workspace,
            .name = command.name,
        });

        return true;
    }
};

const RequestCapture = struct {
    blocked: bool = false,
    failure: ?anyerror = null,
    calls: usize = 0,
    workspace: ?schema.WorkspaceLocation = null,
    name: [schema.max_tab_label_bytes]u8 = undefined,
    name_len: u8 = 0,

    fn gate(capture: *RequestCapture) WorkspaceOperationGate {
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
        capture.workspace = requested.workspace;
        capture.name_len = @intCast(requested.name.len);
        @memcpy(capture.name[0..requested.name.len], requested.name);

        if (capture.failure) |failure| {
            return failure;
        }
    }

    fn nameSlice(capture: *const RequestCapture) []const u8 {
        return capture.name[0..capture.name_len];
    }
};

const TestingModel = struct {
    model: *client_model.Model,
    workspace: schema.WorkspaceLocation,

    fn init() !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();

        const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
        try model.workspace.bootstrap(@enumFromInt(1), .{
            .workspace = workspace,
            .tab_id = @enumFromInt(1),
        }, .{ .cols = 20, .rows = 5 });

        return .{ .model = model, .workspace = workspace };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }
};

test "RequestRenameWorkspaceHandler sends the current target without provisional mutation" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RequestCapture = .{};
    var handler: RequestRenameWorkspaceHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.effects(),
    };

    try std.testing.expect(try handler.execute(.{
        .workspace = testing.workspace,
        .name = "agents",
    }));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualDeep(testing.workspace, capture.workspace.?);
    try std.testing.expectEqualStrings("agents", capture.nameSlice());
    try std.testing.expectEqualStrings("", testing.model.workspace.workspaceName());
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "RequestRenameWorkspaceHandler suppresses blocked and stale targets" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RequestCapture = .{ .blocked = true };
    var handler: RequestRenameWorkspaceHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.effects(),
    };

    try std.testing.expect(!try handler.execute(.{
        .workspace = testing.workspace,
        .name = "blocked",
    }));
    capture.blocked = false;
    try std.testing.expect(!try handler.execute(.{
        .workspace = .{ .workspace = @enumFromInt(9) },
        .name = "stale",
    }));

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "RequestRenameWorkspaceHandler propagates delivery failure without mutation" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RequestCapture = .{ .failure = error.DeliveryFailed };
    var handler: RequestRenameWorkspaceHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.effects(),
    };

    try std.testing.expectError(error.DeliveryFailed, handler.execute(.{
        .workspace = testing.workspace,
        .name = "agents",
    }));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualStrings("", testing.model.workspace.workspaceName());
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}
