//! Application use cases for requesting and confirming a tab move.

const MoveTabTestingModel = @import("MoveTabTestingModel.zig");
const MoveTabRequestCapture = @import("MoveTabRequestCapture.zig");
const RequestTabMoveHandler = @import("RequestTabMoveHandler.zig");
const std = @import("std");
const TabMoveIntent = @import("TabMoveIntent.zig");
const VersionType = @import("../../model/Version.zig");
const ConfirmTabMoveHandler = @import("ConfirmTabMoveHandler.zig");
const types = @import("../../model/types.zig");
const TabLocationType = @import("telar-core").TabLocation;

test "tab move request sends the active identity without provisional mutation" {
    var testing = try MoveTabTestingModel.init();
    defer testing.deinit();
    var capture: MoveTabRequestCapture = .{};
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
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "tab move request suppresses blocked and absent targets" {
    var testing = try MoveTabTestingModel.init();
    defer testing.deinit();
    var capture: MoveTabRequestCapture = .{ .blocked = true };
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
    var testing = try MoveTabTestingModel.init();
    defer testing.deinit();
    var capture: MoveTabRequestCapture = .{ .fail = true };
    var handler: RequestTabMoveHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.effects(),
    };

    try std.testing.expectError(error.DeliveryFailed, handler.execute(.{ .direction = .next }));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(@as(?usize, 1), testing.model.workspace.indexOf(testing.second.tab_id));
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "tab move confirmation commits the canonical position and preserves active identity" {
    var testing = try MoveTabTestingModel.init();
    defer testing.deinit();
    var handler: ConfirmTabMoveHandler = .{ .model = testing.model };

    const change = try handler.execute(.{ .location = testing.second, .position = 0 });

    try std.testing.expectEqual(types.Change.changed, change);
    try std.testing.expectEqual(@as(?usize, 0), testing.model.workspace.indexOf(testing.second.tab_id));
    try std.testing.expectEqualDeep(testing.second, testing.model.activeTabLocation().?);
    try std.testing.expectEqual(@as(u64, 1), testing.model.version().tabs);
    try std.testing.expectEqual(@as(u64, 0), testing.model.version().active_tab);
}

test "tab move confirmation preserves the version for a canonical no-op" {
    var testing = try MoveTabTestingModel.init();
    defer testing.deinit();
    var handler: ConfirmTabMoveHandler = .{ .model = testing.model };

    const change = try handler.execute(.{ .location = testing.second, .position = 1 });

    try std.testing.expectEqual(types.Change.unchanged, change);
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "tab move confirmation rejects invalid canonical state without mutation" {
    var testing = try MoveTabTestingModel.init();
    defer testing.deinit();
    var handler: ConfirmTabMoveHandler = .{ .model = testing.model };
    const other_workspace: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(9) },
        .tab_id = testing.second.tab_id,
    };
    const missing_tab: TabLocationType = .{
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
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}
