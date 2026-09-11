//! Application policy for one runtime resynchronization requirement.

const std = @import("std");
const core = @import("telar-core");

pub const schema = core.schema;

pub const Reconciliation = @import("Reconciliation.zig");

pub const WorkspaceClosure = @import("WorkspaceClosure.zig");

pub const Command = union(enum) {
    reconcile: Reconciliation,
    workspace_closed: WorkspaceClosure,
};

pub const Effects = @import("ResyncRequiredEffects.zig");

pub const Outcome = enum {
    coalesced,
    snapshot_requested,
    handoff_requested,
    exit,
};

pub const HandleResyncRequiredHandler = @import("HandleResyncRequiredHandler.zig");

pub const EffectEvent = enum {
    forget_workspace,
    request_snapshot,
    request_handoff,
};

const EffectsCapture = @import("ResyncRequiredEffectsCapture.zig");

const testing_workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(7) };

fn reconciliation(projected_workspace: ?schema.WorkspaceLocation, snapshot_pending: bool) Command {
    return .{ .reconcile = .{
        .required_workspace = testing_workspace,
        .projected_workspace = projected_workspace,
        .snapshot_pending = snapshot_pending,
    } };
}

test "resync requests one snapshot for the current projected workspace" {
    var capture: EffectsCapture = .{};
    var handler = capture.handler();

    try std.testing.expectEqual(
        Outcome.snapshot_requested,
        try handler.execute(reconciliation(testing_workspace, false)),
    );
    try std.testing.expectEqualSlices(
        EffectEvent,
        &.{.request_snapshot},
        capture.events[0..capture.event_count],
    );
    try std.testing.expectEqualDeep(testing_workspace, capture.snapshot_workspace.?);
}

test "resync rejects a missing or different projected workspace without effects" {
    const cases = [_]?schema.WorkspaceLocation{
        null,
        .{ .workspace = @enumFromInt(8) },
        .{ .worktree = @enumFromInt(1) },
    };

    for (cases) |projected| {
        var capture: EffectsCapture = .{};
        var handler = capture.handler();

        try std.testing.expectError(
            error.UnexpectedResync,
            handler.execute(reconciliation(projected, false)),
        );
        try std.testing.expectEqual(@as(usize, 0), capture.event_count);
    }
}

test "resync coalesces while a workspace snapshot is pending" {
    var capture: EffectsCapture = .{};
    var handler = capture.handler();

    try std.testing.expectEqual(
        Outcome.coalesced,
        try handler.execute(reconciliation(testing_workspace, true)),
    );
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "closed workspace forgets its bookmark before following the predecessor" {
    var capture: EffectsCapture = .{};
    var handler = capture.handler();

    try std.testing.expectEqual(
        Outcome.handoff_requested,
        try handler.execute(.{ .workspace_closed = .{
            .workspace = testing_workspace,
            .previous_workspace = @enumFromInt(6),
        } }),
    );
    try std.testing.expectEqualSlices(
        EffectEvent,
        &.{ .forget_workspace, .request_handoff },
        capture.events[0..capture.event_count],
    );
    try std.testing.expectEqualDeep(testing_workspace, capture.forgotten_workspace.?);
    try std.testing.expectEqual(@as(schema.WorkspaceId, @enumFromInt(6)), capture.handoff_workspace.?);
}

test "closed final workspace forgets its bookmark before exit" {
    var capture: EffectsCapture = .{};
    var handler = capture.handler();

    try std.testing.expectEqual(
        Outcome.exit,
        try handler.execute(.{ .workspace_closed = .{
            .workspace = testing_workspace,
            .previous_workspace = null,
        } }),
    );
    try std.testing.expectEqualSlices(
        EffectEvent,
        &.{.forget_workspace},
        capture.events[0..capture.event_count],
    );
    try std.testing.expectEqualDeep(testing_workspace, capture.forgotten_workspace.?);
}

test "resync preserves completed effects when delivery fails" {
    var snapshot_capture: EffectsCapture = .{ .fail_snapshot = true };
    var snapshot_handler = snapshot_capture.handler();

    try std.testing.expectError(
        error.SnapshotRequestFailed,
        snapshot_handler.execute(reconciliation(testing_workspace, false)),
    );
    try std.testing.expectEqualSlices(
        EffectEvent,
        &.{.request_snapshot},
        snapshot_capture.events[0..snapshot_capture.event_count],
    );

    var handoff_capture: EffectsCapture = .{ .fail_handoff = true };
    var handoff_handler = handoff_capture.handler();

    try std.testing.expectError(
        error.HandoffRequestFailed,
        handoff_handler.execute(.{ .workspace_closed = .{
            .workspace = testing_workspace,
            .previous_workspace = @enumFromInt(6),
        } }),
    );
    try std.testing.expectEqualSlices(
        EffectEvent,
        &.{ .forget_workspace, .request_handoff },
        handoff_capture.events[0..handoff_capture.event_count],
    );
    try std.testing.expectEqualDeep(testing_workspace, handoff_capture.forgotten_workspace.?);
}
