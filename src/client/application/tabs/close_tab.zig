//! Application use cases for requesting closure and applying tab removal.

const ApplyTabRemoval = @import("ApplyTabRemoval.zig");
const CloseTabTestingModel = @import("CloseTabTestingModel.zig");
const CloseTabRequestCapture = @import("CloseTabRequestCapture.zig");
const RequestCloseTabHandler = @import("RequestCloseTabHandler.zig");
const std = @import("std");
const VersionType = @import("../../model/Version.zig");
const RecoverCloseTabHandler = @import("RecoverCloseTabHandler.zig");
const RemovalCapture = @import("RemovalCapture.zig");
const ApplyTabRemovalHandler = @import("ApplyTabRemovalHandler.zig");
const TabLocationType = @import("telar-core").TabLocation;
const types = @import("../../model/types.zig");
const WorkspaceIdType = @import("telar-core").WorkspaceId;

pub const RemovalTrigger = enum {
    requested,
    lifecycle,
};

pub const TabRemovalDirective = enum {
    continue_running,
    exit,
};

pub fn validateWorkspaceTransition(command: ApplyTabRemoval) !void {
    if (!command.workspace_removed and command.previous_workspace != null) {
        return error.UnexpectedPreviousWorkspace;
    }

    const previous = command.previous_workspace orelse return;
    const removed = switch (command.location.workspace) {
        .workspace => |workspace| workspace,
        .worktree => return error.InvalidWorkspaceSuccessor,
    };

    if (previous == removed) {
        return error.InvalidWorkspaceSuccessor;
    }
}

pub const RequestStep = enum {
    prepare,
    detach,
    send,
    restore,
};

test "tab close request prepares and detaches before delivery" {
    var testing = try CloseTabTestingModel.init(true);
    defer testing.deinit();
    var capture: CloseTabRequestCapture = .{ .blocked = true };
    var handler: RequestCloseTabHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .preparation = capture.preparation(),
        .snapshots = capture.snapshots(),
        .effects = capture.requestEffects(),
    };

    try std.testing.expect(!try handler.execute());
    try std.testing.expectEqual(@as(usize, 0), capture.recorded().len);
    capture.blocked = false;

    try std.testing.expect(try handler.execute());
    try std.testing.expectEqualSlices(RequestStep, &.{ .prepare, .detach, .send }, capture.recorded());
    try std.testing.expectEqualDeep(testing.first, capture.intent.?.location);
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "tab close request suppresses an absent active tab" {
    var testing = try CloseTabTestingModel.init(false);
    defer testing.deinit();
    _ = testing.model.departWorkspace();
    var capture: CloseTabRequestCapture = .{};
    var handler: RequestCloseTabHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .preparation = capture.preparation(),
        .snapshots = capture.snapshots(),
        .effects = capture.requestEffects(),
    };

    try std.testing.expect(!try handler.execute());
    try std.testing.expectEqual(@as(usize, 0), capture.recorded().len);
}

test "tab close request rejects preparation without provisional effects" {
    var testing = try CloseTabTestingModel.init(true);
    defer testing.deinit();
    var capture: CloseTabRequestCapture = .{ .prepare_failure = error.NoDeliveryCapacity };
    var handler: RequestCloseTabHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .preparation = capture.preparation(),
        .snapshots = capture.snapshots(),
        .effects = capture.requestEffects(),
    };

    try std.testing.expectError(error.NoDeliveryCapacity, handler.execute());
    try std.testing.expectEqualSlices(RequestStep, &.{.prepare}, capture.recorded());
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "tab close request restores every failure after preparation" {
    var testing = try CloseTabTestingModel.init(true);
    defer testing.deinit();

    var detach_failure: CloseTabRequestCapture = .{ .detach_failure = error.DetachFailed };
    var detach_handler: RequestCloseTabHandler = .{
        .model = testing.model,
        .gate = detach_failure.gate(),
        .preparation = detach_failure.preparation(),
        .snapshots = detach_failure.snapshots(),
        .effects = detach_failure.requestEffects(),
    };
    try std.testing.expectError(error.DetachFailed, detach_handler.execute());
    try std.testing.expectEqualSlices(RequestStep, &.{ .prepare, .detach, .restore }, detach_failure.recorded());

    var send_failure: CloseTabRequestCapture = .{ .send_failure = error.SendFailed };
    var send_handler: RequestCloseTabHandler = .{
        .model = testing.model,
        .gate = send_failure.gate(),
        .preparation = send_failure.preparation(),
        .snapshots = send_failure.snapshots(),
        .effects = send_failure.requestEffects(),
    };
    try std.testing.expectError(error.SendFailed, send_handler.execute());
    try std.testing.expectEqualSlices(RequestStep, &.{ .prepare, .detach, .send, .restore }, send_failure.recorded());
}

test "tab close request reports a failed repair after provisional failure" {
    var testing = try CloseTabTestingModel.init(true);
    defer testing.deinit();
    var capture: CloseTabRequestCapture = .{
        .send_failure = error.SendFailed,
        .restore_failure = error.RestoreFailed,
    };
    var handler: RequestCloseTabHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .preparation = capture.preparation(),
        .snapshots = capture.snapshots(),
        .effects = capture.requestEffects(),
    };

    try std.testing.expectError(error.RestoreFailed, handler.execute());
    try std.testing.expectEqualSlices(RequestStep, &.{ .prepare, .detach, .send, .restore }, capture.recorded());
}

test "close rejection restores only the still-active tab" {
    var testing = try CloseTabTestingModel.init(true);
    defer testing.deinit();
    var capture: CloseTabRequestCapture = .{};
    var handler: RecoverCloseTabHandler = .{
        .model = testing.model,
        .snapshots = capture.snapshots(),
    };

    try std.testing.expect(!try handler.execute(testing.second));
    try std.testing.expectEqual(@as(usize, 0), capture.recorded().len);
    try std.testing.expect(try handler.execute(testing.first));
    try std.testing.expectEqualSlices(RequestStep, &.{.restore}, capture.recorded());
}

test "tab removal commits before delivery" {
    var testing = try CloseTabTestingModel.init(true);
    defer testing.deinit();
    var capture: RemovalCapture = .{ .model = testing.model };
    var handler: ApplyTabRemovalHandler = .{
        .model = testing.model,
        .delivery = capture.port(),
    };

    const directive = try handler.execute(.{
        .location = testing.first,
        .workspace_removed = false,
        .previous_workspace = null,
        .trigger = .requested,
    });

    try std.testing.expectEqual(TabRemovalDirective.continue_running, directive);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.commit.? == .removed);
    try std.testing.expect(capture.previous_workspace == null);
    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqualDeep(testing.second, testing.model.activeTabLocation().?);
    try std.testing.expectEqual(@as(u64, 1), testing.model.version().tabs);
    try std.testing.expectEqual(@as(u64, 1), testing.model.version().active_tab);
}

test "requested tab removal rejects invalid or missing canonical state" {
    var testing = try CloseTabTestingModel.init(true);
    defer testing.deinit();
    var capture: RemovalCapture = .{ .model = testing.model };
    var handler: ApplyTabRemovalHandler = .{
        .model = testing.model,
        .delivery = capture.port(),
    };

    try std.testing.expectError(error.UnexpectedPreviousWorkspace, handler.execute(.{
        .location = testing.first,
        .workspace_removed = false,
        .previous_workspace = @enumFromInt(9),
        .trigger = .requested,
    }));
    try std.testing.expectError(error.UnexpectedWorkspaceRemoval, handler.execute(.{
        .location = testing.first,
        .workspace_removed = true,
        .previous_workspace = null,
        .trigger = .requested,
    }));
    try std.testing.expectError(error.UnexpectedTab, handler.execute(.{
        .location = .{
            .workspace = testing.first.workspace,
            .tab_id = @enumFromInt(9),
        },
        .workspace_removed = false,
        .previous_workspace = null,
        .trigger = .requested,
    }));

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expectEqual(@as(usize, 2), testing.model.workspace.count);
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "repeated lifecycle tab removal delivers an exact stale commit without mutation" {
    var testing = try CloseTabTestingModel.init(true);
    defer testing.deinit();
    var capture: RemovalCapture = .{ .model = testing.model };
    var handler: ApplyTabRemovalHandler = .{
        .model = testing.model,
        .delivery = capture.port(),
    };
    const missing: TabLocationType = .{
        .workspace = testing.first.workspace,
        .tab_id = @enumFromInt(9),
    };

    try std.testing.expectEqual(TabRemovalDirective.continue_running, try handler.execute(.{
        .location = missing,
        .workspace_removed = false,
        .previous_workspace = null,
        .trigger = .lifecycle,
    }));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.commit.? == .stale);
    try std.testing.expectEqualDeep(missing, capture.commit.?.stale.location);
    try std.testing.expectEqual(types.TabRemovalAbsence.tab, capture.commit.?.stale.absence);
    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(@as(usize, 2), testing.model.workspace.count);
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "stale lifecycle tab removal from a departed workspace is ignored" {
    var testing = try CloseTabTestingModel.init(true);
    defer testing.deinit();
    const stale = testing.second;
    _ = testing.model.departWorkspace();
    try testing.model.workspace.bootstrap(.{ .pane_id = @enumFromInt(7), .location = .{
        .workspace = .{ .workspace = @enumFromInt(7) },
        .tab_id = @enumFromInt(7),
    }, .size = .{ .cols = 20, .rows = 5 } });
    var capture: RemovalCapture = .{ .model = testing.model };
    var handler: ApplyTabRemovalHandler = .{
        .model = testing.model,
        .delivery = capture.port(),
    };
    const version = testing.model.version();

    try std.testing.expectEqual(TabRemovalDirective.continue_running, try handler.execute(.{
        .location = stale,
        .workspace_removed = false,
        .previous_workspace = null,
        .trigger = .lifecycle,
    }));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.commit.? == .stale);
    try std.testing.expectEqual(types.TabRemovalAbsence.workspace, capture.commit.?.stale.absence);
    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqualDeep(version, testing.model.version());
}

test "final workspace removal propagates the delivery directive and predecessor" {
    inline for (.{
        .{ .previous = @as(?WorkspaceIdType, null), .expected = TabRemovalDirective.exit },
        .{ .previous = @as(?WorkspaceIdType, @enumFromInt(9)), .expected = TabRemovalDirective.continue_running },
    }) |scenario| {
        var testing = try CloseTabTestingModel.init(false);
        defer testing.deinit();
        var capture: RemovalCapture = .{
            .model = testing.model,
            .directive = scenario.expected,
        };
        var handler: ApplyTabRemovalHandler = .{
            .model = testing.model,
            .delivery = capture.port(),
        };

        try std.testing.expectEqual(scenario.expected, try handler.execute(.{
            .location = testing.first,
            .workspace_removed = true,
            .previous_workspace = scenario.previous,
            .trigger = .lifecycle,
        }));

        try std.testing.expectEqual(@as(usize, 1), capture.calls);
        try std.testing.expect(capture.commit.? == .removed);
        try std.testing.expect(capture.observed_commit);
        try std.testing.expectEqual(scenario.previous, capture.previous_workspace);
        try std.testing.expect(testing.model.workspaceLocation() == null);
    }
}

test "tab removal preserves its commit after delivery failure" {
    var testing = try CloseTabTestingModel.init(true);
    defer testing.deinit();
    var capture: RemovalCapture = .{
        .model = testing.model,
        .failure = error.ResourceSyncFailed,
    };
    var handler: ApplyTabRemovalHandler = .{
        .model = testing.model,
        .delivery = capture.port(),
    };

    try std.testing.expectError(error.ResourceSyncFailed, handler.execute(.{
        .location = testing.first,
        .workspace_removed = false,
        .previous_workspace = null,
        .trigger = .requested,
    }));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqualDeep(testing.second, testing.model.activeTabLocation().?);
}

test "final removal preserves its commit after delivery failure" {
    var testing = try CloseTabTestingModel.init(false);
    defer testing.deinit();
    var capture: RemovalCapture = .{
        .model = testing.model,
        .failure = error.HandoffFailed,
    };
    var handler: ApplyTabRemovalHandler = .{
        .model = testing.model,
        .delivery = capture.port(),
    };

    try std.testing.expectError(error.HandoffFailed, handler.execute(.{
        .location = testing.first,
        .workspace_removed = true,
        .previous_workspace = @enumFromInt(9),
        .trigger = .lifecycle,
    }));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(@as(?WorkspaceIdType, @enumFromInt(9)), capture.previous_workspace);
    try std.testing.expect(testing.model.workspaceLocation() == null);
}
