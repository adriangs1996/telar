//! Application use cases for requesting and confirming tab creation.

const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const std = @import("std");
const CreateTabTestingModel = @import("CreateTabTestingModel.zig");
const CreateTabRequestCapture = @import("CreateTabRequestCapture.zig");
const RequestTabCreationHandler = @import("RequestTabCreationHandler.zig");
const PaneIdType = @import("telar-core").PaneId;
const VersionType = @import("../../model/Version.zig");
const DeliveryCapture = @import("DeliveryCapture.zig");
const ConfirmTabCreationHandler = @import("ConfirmTabCreationHandler.zig");

pub fn validateLabel(label: []const u8) !void {
    if (label.len > max_tab_label_bytes_module) {
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

test "tab creation request sends the current workspace and focused pane without mutation" {
    var testing = try CreateTabTestingModel.init();
    defer testing.deinit();
    var capture: CreateTabRequestCapture = .{};
    var handler: RequestTabCreationHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.effects(),
    };

    try std.testing.expect(try handler.execute(.{ .label = "logs" }));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualDeep(testing.first.workspace, capture.workspace.?);
    try std.testing.expectEqual(@as(PaneIdType, @enumFromInt(1)), capture.cwd_source.?);
    try std.testing.expectEqualStrings("logs", capture.labelSlice());
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "tab creation request suppresses blocked and absent launch sources" {
    var testing = try CreateTabTestingModel.init();
    defer testing.deinit();
    var capture: CreateTabRequestCapture = .{ .blocked = true };
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
    var testing = try CreateTabTestingModel.init();
    defer testing.deinit();
    var capture: CreateTabRequestCapture = .{};
    var handler: RequestTabCreationHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.effects(),
    };
    var too_long: [max_tab_label_bytes_module + 1]u8 = @splat('a');
    const invalid_utf8 = [_]u8{0xff};

    try std.testing.expectError(error.InvalidTabLabel, handler.execute(.{ .label = &too_long }));
    try std.testing.expectError(error.InvalidTabLabel, handler.execute(.{ .label = "bad\nlabel" }));
    try std.testing.expectError(error.InvalidUtf8, handler.execute(.{ .label = &invalid_utf8 }));

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "tab creation request propagates delivery failure without mutation" {
    var testing = try CreateTabTestingModel.init();
    defer testing.deinit();
    var capture: CreateTabRequestCapture = .{ .fail = true };
    var handler: RequestTabCreationHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.effects(),
    };

    try std.testing.expectError(error.DeliveryFailed, handler.execute(.{}));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "ConfirmTabCreationHandler commits before delivery" {
    var testing = try CreateTabTestingModel.init();
    defer testing.deinit();
    var delivery: DeliveryCapture = .{ .model = testing.model, .expected = testing.second };
    var handler: ConfirmTabCreationHandler = .{
        .model = testing.model,
        .delivery = delivery.port(),
    };

    const creation = try handler.execute(testing.command());

    try std.testing.expectEqualDeep(testing.first, creation.previous);
    try std.testing.expectEqualDeep(testing.second, creation.created);
    try std.testing.expectEqual(@as(usize, 1), delivery.calls);
    try std.testing.expect(delivery.observed_commit);
}

test "ConfirmTabCreationHandler rejects model failures before delivery" {
    var testing = try CreateTabTestingModel.init();
    defer testing.deinit();
    var delivery: DeliveryCapture = .{ .model = testing.model, .expected = testing.second };
    var handler: ConfirmTabCreationHandler = .{
        .model = testing.model,
        .delivery = delivery.port(),
    };
    var command = testing.command();
    command.created.location.workspace = .{ .workspace = @enumFromInt(9) };

    try std.testing.expectError(error.UnexpectedWorkspace, handler.execute(command));

    try std.testing.expectEqual(@as(usize, 0), delivery.calls);
    try std.testing.expectEqual(@as(usize, 1), testing.model.workspace.count);
    try std.testing.expectEqualDeep(testing.first, testing.model.activeTabLocation().?);
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "ConfirmTabCreationHandler preserves a committed creation after delivery failure" {
    var testing = try CreateTabTestingModel.init();
    defer testing.deinit();
    var delivery: DeliveryCapture = .{
        .model = testing.model,
        .expected = testing.second,
        .fail = true,
    };
    var handler: ConfirmTabCreationHandler = .{
        .model = testing.model,
        .delivery = delivery.port(),
    };

    try std.testing.expectError(error.CreationSyncFailed, handler.execute(testing.command()));

    try std.testing.expectEqualDeep(testing.second, testing.model.activeTabLocation().?);
    try std.testing.expectEqual(@as(usize, 2), testing.model.workspace.count);
    try std.testing.expectEqual(@as(u64, 1), testing.model.version().tabs);
    try std.testing.expectEqual(@as(u64, 1), testing.model.version().active_tab);
    try std.testing.expect(delivery.observed_commit);
}
