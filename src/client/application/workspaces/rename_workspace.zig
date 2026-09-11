//! Application use case for requesting one workspace rename.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../root.zig").model;

pub const schema = core.schema;

pub const RequestRenameWorkspace = @import("RequestRenameWorkspace.zig");

pub const RequestedRename = @import("RequestedRename.zig");

pub const WorkspaceOperationGate = @import("RenameWorkspaceWorkspaceOperationGate.zig");

pub const RenameRequestEffects = @import("RenameRequestEffects.zig");

pub const RequestRenameWorkspaceHandler = @import("RequestRenameWorkspaceHandler.zig");

const RequestCapture = @import("RenameWorkspaceRequestCapture.zig");

const TestingModel = @import("RenameWorkspaceTestingModel.zig");

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
