//! Application use cases for leaving, entering and recovering a workspace handoff.

const WorkspaceIdType = @import("telar-core").WorkspaceId;
const ModelType = @import("../../model/Model.zig");
const WorkspaceHandoffTestingModel = @import("WorkspaceHandoffTestingModel.zig");
const SelectionCapture = @import("SelectionCapture.zig");
const SelectWorkspaceHandler = @import("SelectWorkspaceHandler.zig");
const std = @import("std");
const WorkspaceHandoff = @import("WorkspaceHandoff.zig");
const WorkspaceHandoffRequestCapture = @import("WorkspaceHandoffRequestCapture.zig");
const RequestWorkspaceHandoffHandler = @import("RequestWorkspaceHandoffHandler.zig");
const VersionType = @import("../../model/Version.zig");
const ArrivalCapture = @import("ArrivalCapture.zig");
const ConfirmWorkspaceHandoffHandler = @import("ConfirmWorkspaceHandoffHandler.zig");
const WorkspaceArrivalType = @import("../../model/WorkspaceArrival.zig");
const RecoveryCapture = @import("RecoveryCapture.zig");
const RecoverWorkspaceHandoffHandler = @import("RecoverWorkspaceHandoffHandler.zig");

pub const SelectionTarget = union(enum) {
    position: usize,
    workspace: WorkspaceIdType,
};

pub const WorkspaceRecovery = enum {
    retried,
    unrecoverable,
};

fn prepareWorkspaceSelection(model: *ModelType) !void {
    _ = try model.reconcileWorkspaceList(.{
        .revision = 1,
        .entries = &.{
            .{ .workspace = @enumFromInt(1), .name = "main", .path = "/work/main", .tab_count = 1 },
            .{ .workspace = @enumFromInt(2), .name = "api", .path = "/work/api", .tab_count = 1 },
        },
    });
}

test "SelectWorkspaceHandler resolves listed positions and identities without mutation" {
    var testing = try WorkspaceHandoffTestingModel.init(true);
    defer testing.deinit();
    try prepareWorkspaceSelection(testing.model);
    var capture: SelectionCapture = .{};
    var handler: SelectWorkspaceHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.port(),
    };
    const version = testing.model.version();

    try std.testing.expect(try handler.execute(.{ .position = 1 }));
    try std.testing.expectEqual(@as(WorkspaceIdType, @enumFromInt(2)), capture.requested.?);
    try std.testing.expect(try handler.execute(.{ .workspace = @enumFromInt(2) }));

    try std.testing.expect(!try handler.execute(.{ .workspace = @enumFromInt(1) }));
    try std.testing.expect(!try handler.execute(.{ .workspace = @enumFromInt(9) }));
    try std.testing.expect(!try handler.execute(.{ .position = 2 }));
    capture.blocked = true;
    try std.testing.expect(!try handler.execute(.{ .position = 1 }));

    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    try std.testing.expectEqualDeep(version, testing.model.version());
}

test "SelectWorkspaceHandler propagates delivery failure without mutation" {
    var testing = try WorkspaceHandoffTestingModel.init(true);
    defer testing.deinit();
    try prepareWorkspaceSelection(testing.model);
    var capture: SelectionCapture = .{ .fail = true };
    var handler: SelectWorkspaceHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.port(),
    };
    const version = testing.model.version();

    try std.testing.expectError(
        error.SelectionDeliveryFailed,
        handler.execute(.{ .workspace = @enumFromInt(2) }),
    );

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(@as(WorkspaceIdType, @enumFromInt(2)), capture.requested.?);
    try std.testing.expectEqualDeep(version, testing.model.version());
}

test "SelectWorkspaceHandler permits base workspace selection from a worktree" {
    var testing = try WorkspaceHandoffTestingModel.init(false);
    defer testing.deinit();
    try testing.model.workspace.bootstrap(.{ .pane_id = @enumFromInt(1), .location = .{
        .workspace = .{ .worktree = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    }, .size = .{ .cols = 20, .rows = 5 } });
    try prepareWorkspaceSelection(testing.model);
    var capture: SelectionCapture = .{};
    var handler: SelectWorkspaceHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.port(),
    };
    const version = testing.model.version();

    try std.testing.expect(try handler.execute(.{ .workspace = @enumFromInt(1) }));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(@as(WorkspaceIdType, @enumFromInt(1)), capture.requested.?);
    try std.testing.expectEqualDeep(version, testing.model.version());
}

pub const RequestEvent = enum {
    prepare,
    detach,
    send,
    restore_graphics,
    restore_snapshot_pending,
    restore_snapshot,
    release,
};

fn testingHandoff() WorkspaceHandoff {
    return .{
        .target = .{ .workspace = @enumFromInt(2) },
        .fallback_workspace = @enumFromInt(2),
        .size = .{ .cols = 30, .rows = 8 },
    };
}

test "RequestWorkspaceHandoffHandler orders effects before one departure commit" {
    var testing = try WorkspaceHandoffTestingModel.init(true);
    defer testing.deinit();
    var capture: WorkspaceHandoffRequestCapture = .{ .model = testing.model };
    var handler: RequestWorkspaceHandoffHandler = .{
        .model = testing.model,
        .admission = capture.admission(),
        .preparation = capture.preparation(),
        .retirement = capture.retirement(),
        .restoration = capture.restoration(),
        .effects = capture.port(),
    };
    const command = testingHandoff();

    const departure = try handler.execute(command, .requested_departure);

    try std.testing.expectEqualSlices(RequestEvent, &.{ .prepare, .detach, .send, .release }, capture.events[0..capture.event_count]);
    try std.testing.expectEqualDeep(command, capture.command.?);
    try std.testing.expectEqualDeep(departure.source, capture.departure.?.source);
    try std.testing.expect(capture.observed_commit);
    try std.testing.expect(testing.model.workspaceLocation() == null);
}

test "RequestWorkspaceHandoffHandler rejects a blocked departure before preflight" {
    var testing = try WorkspaceHandoffTestingModel.init(true);
    defer testing.deinit();
    var capture: WorkspaceHandoffRequestCapture = .{ .model = testing.model, .blocked = true };
    var handler: RequestWorkspaceHandoffHandler = .{
        .model = testing.model,
        .admission = capture.admission(),
        .preparation = capture.preparation(),
        .retirement = capture.retirement(),
        .restoration = capture.restoration(),
        .effects = capture.port(),
    };

    try std.testing.expectError(
        error.WorkspaceSwitchWhileRequestPending,
        handler.execute(testingHandoff(), .requested_departure),
    );

    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
    try std.testing.expectEqualDeep(testing.location, testing.model.activeTabLocation().?);
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "RequestWorkspaceHandoffHandler rejects a canonical follow from an active projection before preflight" {
    var testing = try WorkspaceHandoffTestingModel.init(true);
    defer testing.deinit();
    var capture: WorkspaceHandoffRequestCapture = .{ .model = testing.model };
    var handler: RequestWorkspaceHandoffHandler = .{
        .model = testing.model,
        .admission = capture.admission(),
        .preparation = capture.preparation(),
        .retirement = capture.retirement(),
        .restoration = capture.restoration(),
        .effects = capture.port(),
    };

    try std.testing.expectError(
        error.WorkspaceStillActive,
        handler.execute(testingHandoff(), .canonical_follow),
    );

    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
    try std.testing.expectEqualDeep(testing.location, testing.model.activeTabLocation().?);
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "RequestWorkspaceHandoffHandler rejects preflight without recovery" {
    var testing = try WorkspaceHandoffTestingModel.init(true);
    defer testing.deinit();
    var capture: WorkspaceHandoffRequestCapture = .{
        .model = testing.model,
        .fail_prepare = true,
    };
    var handler: RequestWorkspaceHandoffHandler = .{
        .model = testing.model,
        .admission = capture.admission(),
        .preparation = capture.preparation(),
        .retirement = capture.retirement(),
        .restoration = capture.restoration(),
        .effects = capture.port(),
    };

    try std.testing.expectError(
        error.PreparationFailed,
        handler.execute(testingHandoff(), .requested_departure),
    );

    try std.testing.expectEqualSlices(RequestEvent, &.{.prepare}, capture.events[0..capture.event_count]);
    try std.testing.expectEqualDeep(testing.location, testing.model.activeTabLocation().?);
    try std.testing.expect(testing.model.workspace.findPane(testing.pane_id).?.attached);
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "RequestWorkspaceHandoffHandler restores local detach and send failures" {
    inline for (.{
        .{
            .detach = true,
            .send = false,
            .restore = false,
            .expected = error.DetachFailed,
            .events = &[_]RequestEvent{ .prepare, .detach, .restore_graphics, .restore_snapshot_pending, .restore_snapshot },
        },
        .{
            .detach = false,
            .send = true,
            .restore = false,
            .expected = error.SendFailed,
            .events = &[_]RequestEvent{ .prepare, .detach, .send, .restore_graphics, .restore_snapshot_pending, .restore_snapshot },
        },
        .{
            .detach = true,
            .send = false,
            .restore = true,
            .expected = error.DetachFailed,
            .events = &[_]RequestEvent{ .prepare, .detach, .restore_graphics },
        },
    }) |scenario| {
        var testing = try WorkspaceHandoffTestingModel.init(true);
        defer testing.deinit();
        var capture: WorkspaceHandoffRequestCapture = .{
            .model = testing.model,
            .fail_detach = scenario.detach,
            .fail_send = scenario.send,
            .fail_restore = scenario.restore,
        };
        var handler: RequestWorkspaceHandoffHandler = .{
            .model = testing.model,
            .admission = capture.admission(),
            .preparation = capture.preparation(),
            .retirement = capture.retirement(),
            .restoration = capture.restoration(),
            .effects = capture.port(),
        };

        try std.testing.expectError(
            scenario.expected,
            handler.execute(testingHandoff(), .requested_departure),
        );

        try std.testing.expectEqualSlices(RequestEvent, scenario.events, capture.events[0..capture.event_count]);
        try std.testing.expectEqualDeep(testing.location, testing.model.activeTabLocation().?);
        try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
    }
}

test "ConfirmWorkspaceHandoffHandler commits before delivery and retains failures" {
    inline for (.{ false, true }) |fail| {
        var testing = try WorkspaceHandoffTestingModel.init(true);
        defer testing.deinit();
        _ = testing.model.departWorkspace();
        const version_before = testing.model.version();
        var capture: ArrivalCapture = .{
            .model = testing.model,
            .expected_before = version_before,
            .fail = fail,
        };
        var handler: ConfirmWorkspaceHandoffHandler = .{
            .model = testing.model,
            .delivery = capture.port(),
        };
        const arrival: WorkspaceArrivalType = .{
            .pane_id = @enumFromInt(9),
            .location = testing.location,
            .size = .{ .cols = 30, .rows = 8 },
        };

        if (fail) {
            try std.testing.expectError(error.ArrivalDeliveryFailed, handler.execute(arrival));
        } else {
            try handler.execute(arrival);
        }

        try std.testing.expectEqual(@as(usize, 1), capture.calls);
        try std.testing.expect(capture.observed_commit);
        try std.testing.expectEqualDeep(testing.location, testing.model.activeTabLocation().?);
        const version = testing.model.version();
        try std.testing.expectEqual(version_before.workspace +% 1, version.workspace);
        try std.testing.expectEqual(version_before.tabs +% 1, version.tabs);
        try std.testing.expectEqual(version_before.active_tab +% 1, version.active_tab);
        try std.testing.expectEqual(version_before.panes +% 1, version.panes);
        try std.testing.expectEqual(version_before.copy, version.copy);
    }
}

test "ConfirmWorkspaceHandoffHandler rejects construction before delivery" {
    var testing = try WorkspaceHandoffTestingModel.init(false);
    defer testing.deinit();
    var capture: ArrivalCapture = .{ .model = testing.model };
    var handler: ConfirmWorkspaceHandoffHandler = .{
        .model = testing.model,
        .delivery = capture.port(),
    };

    try std.testing.expectError(error.InvalidPaneId, handler.execute(.{
        .pane_id = .invalid,
        .location = testing.location,
        .size = .{ .cols = 30, .rows = 8 },
    }));

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expect(testing.model.workspaceLocation() == null);
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "RecoverWorkspaceHandoffHandler retries only a vanished remembered pane" {
    const workspace: WorkspaceIdType = @enumFromInt(7);
    var capture: RecoveryCapture = .{};
    var handler: RecoverWorkspaceHandoffHandler = .{ .effects = capture.port() };

    try std.testing.expectEqual(WorkspaceRecovery.unrecoverable, try handler.execute(.{
        .fallback_workspace = null,
        .code = .pane_not_found,
    }));
    try std.testing.expectEqual(WorkspaceRecovery.unrecoverable, try handler.execute(.{
        .fallback_workspace = workspace,
        .code = .internal,
    }));
    try std.testing.expect(capture.forgotten == null);
    try std.testing.expect(capture.retried == null);

    try std.testing.expectEqual(WorkspaceRecovery.retried, try handler.execute(.{
        .fallback_workspace = workspace,
        .code = .pane_not_found,
    }));
    try std.testing.expectEqual(workspace, capture.forgotten.?);
    try std.testing.expectEqual(workspace, capture.retried.?);
}

test "RecoverWorkspaceHandoffHandler retains stale-bookmark removal after retry failure" {
    const workspace: WorkspaceIdType = @enumFromInt(7);
    var capture: RecoveryCapture = .{ .fail = true };
    var handler: RecoverWorkspaceHandoffHandler = .{ .effects = capture.port() };

    try std.testing.expectError(error.RetryFailed, handler.execute(.{
        .fallback_workspace = workspace,
        .code = .pane_not_found,
    }));

    try std.testing.expectEqual(workspace, capture.forgotten.?);
    try std.testing.expectEqual(workspace, capture.retried.?);
}
