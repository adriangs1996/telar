//! Application use cases for requesting and confirming workspace creation.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../root.zig").model;

pub const schema = core.schema;

pub const RequestWorkspaceCreation = @import("RequestWorkspaceCreation.zig");

pub const WorkspaceCreation = @import("WorkspaceCreation.zig");

pub const WorkspaceOperationGate = @import("CreateWorkspaceWorkspaceOperationGate.zig");

pub const CreationRequestEffects = @import("CreationRequestEffects.zig");

pub const RequestWorkspaceCreationHandler = @import("RequestWorkspaceCreationHandler.zig");

pub const ConfirmWorkspaceCreation = @import("ConfirmWorkspaceCreation.zig");

pub const WorkspaceCreationDelivery = @import("WorkspaceCreationDelivery.zig");

pub const ConfirmWorkspaceCreationHandler = @import("ConfirmWorkspaceCreationHandler.zig");

pub fn validateName(name: []const u8) !void {
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

const TestingModel = @import("CreateWorkspaceTestingModel.zig");

const RequestCapture = @import("CreateWorkspaceRequestCapture.zig");

const DeliveryCapture = @import("DeliveryCapture.zig");

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

test "workspace creation confirmation replaces the projection before delivery" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const arrival = testing.arrival();
    var capture: DeliveryCapture = .{
        .model = testing.model,
        .expected = arrival.location,
    };
    var handler: ConfirmWorkspaceCreationHandler = .{
        .model = testing.model,
        .delivery = capture.delivery(),
    };

    const replacement = try handler.execute(.{ .created = true, .arrival = arrival });

    try std.testing.expectEqualDeep(arrival.location, replacement.activation.location);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.observed_commit);
}

test "workspace creation confirmation rejects an uncreated response before mutation" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const arrival = testing.arrival();
    var capture: DeliveryCapture = .{
        .model = testing.model,
        .expected = arrival.location,
    };
    var handler: ConfirmWorkspaceCreationHandler = .{
        .model = testing.model,
        .delivery = capture.delivery(),
    };

    try std.testing.expectError(error.UnexpectedRequest, handler.execute(.{
        .created = false,
        .arrival = arrival,
    }));

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expectEqualDeep(testing.location, testing.model.activeTabLocation().?);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "workspace creation confirmation rejects model failures before delivery" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var arrival = testing.arrival();
    arrival.location.workspace = testing.location.workspace;
    var capture: DeliveryCapture = .{
        .model = testing.model,
        .expected = arrival.location,
    };
    var handler: ConfirmWorkspaceCreationHandler = .{
        .model = testing.model,
        .delivery = capture.delivery(),
    };

    try std.testing.expectError(error.WorkspaceAlreadyActive, handler.execute(.{
        .created = true,
        .arrival = arrival,
    }));

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expectEqualDeep(testing.location, testing.model.activeTabLocation().?);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "workspace creation confirmation preserves its commit after delivery failure" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const arrival = testing.arrival();
    var capture: DeliveryCapture = .{
        .model = testing.model,
        .expected = arrival.location,
        .fail = true,
    };
    var handler: ConfirmWorkspaceCreationHandler = .{
        .model = testing.model,
        .delivery = capture.delivery(),
    };

    try std.testing.expectError(error.CreationSyncFailed, handler.execute(.{
        .created = true,
        .arrival = arrival,
    }));

    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqualDeep(arrival.location, testing.model.activeTabLocation().?);
    try std.testing.expectEqual(@as(u64, 1), testing.model.version().workspace);
}
