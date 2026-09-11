//! Application use case for requesting one workspace rename.

const RenameWorkspaceTestingModel = @import("RenameWorkspaceTestingModel.zig");
const RenameWorkspaceRequestCapture = @import("RenameWorkspaceRequestCapture.zig");
const RequestRenameWorkspaceHandler = @import("RequestRenameWorkspaceHandler.zig");
const std = @import("std");
const VersionType = @import("../../model/Version.zig");

test "RequestRenameWorkspaceHandler sends the current target without provisional mutation" {
    var testing = try RenameWorkspaceTestingModel.init();
    defer testing.deinit();
    var capture: RenameWorkspaceRequestCapture = .{};
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
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "RequestRenameWorkspaceHandler suppresses blocked and stale targets" {
    var testing = try RenameWorkspaceTestingModel.init();
    defer testing.deinit();
    var capture: RenameWorkspaceRequestCapture = .{ .blocked = true };
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
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "RequestRenameWorkspaceHandler propagates delivery failure without mutation" {
    var testing = try RenameWorkspaceTestingModel.init();
    defer testing.deinit();
    var capture: RenameWorkspaceRequestCapture = .{ .failure = error.DeliveryFailed };
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
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}
