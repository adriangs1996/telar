//! Application policy for one runtime resynchronization requirement.

const std = @import("std");
const core = @import("telar-core");

const schema = core.schema;

pub const Reconciliation = struct {
    required_workspace: schema.WorkspaceLocation,
    projected_workspace: ?schema.WorkspaceLocation,
    snapshot_pending: bool,
};

pub const WorkspaceClosure = struct {
    workspace: schema.WorkspaceLocation,
    previous_workspace: ?schema.WorkspaceId,
};

pub const Command = union(enum) {
    reconcile: Reconciliation,
    workspace_closed: WorkspaceClosure,
};

pub const Effects = struct {
    context: *anyopaque,
    forget_workspace: *const fn (*anyopaque, schema.WorkspaceLocation) void,
    request_snapshot: *const fn (*anyopaque, schema.WorkspaceLocation) anyerror!void,
    request_handoff: *const fn (*anyopaque, schema.WorkspaceId) anyerror!void,
};

pub const Outcome = enum {
    coalesced,
    snapshot_requested,
    handoff_requested,
    exit,
};

pub const HandleResyncRequiredHandler = struct {
    effects: Effects,

    /// Reconciles the current workspace or follows the runtime after closure.
    /// A closed workspace loses its bookmark before handoff or exit.
    ///
    /// ```zig
    /// const outcome = try handler.execute(command);
    /// ```
    pub fn execute(handler: *HandleResyncRequiredHandler, command: Command) !Outcome {
        return switch (command) {
            .reconcile => |state| handler.reconcile(state),
            .workspace_closed => |closure| handler.closeWorkspace(closure),
        };
    }

    fn reconcile(handler: *HandleResyncRequiredHandler, command: Reconciliation) !Outcome {
        const projected = command.projected_workspace orelse return error.UnexpectedResync;
        if (!std.meta.eql(projected, command.required_workspace)) {
            return error.UnexpectedResync;
        }

        if (command.snapshot_pending) {
            return .coalesced;
        }

        try handler.effects.request_snapshot(handler.effects.context, command.required_workspace);
        return .snapshot_requested;
    }

    fn closeWorkspace(handler: *HandleResyncRequiredHandler, command: WorkspaceClosure) !Outcome {
        handler.effects.forget_workspace(handler.effects.context, command.workspace);

        const previous = command.previous_workspace orelse return .exit;
        try handler.effects.request_handoff(handler.effects.context, previous);

        return .handoff_requested;
    }
};

const EffectEvent = enum {
    forget_workspace,
    request_snapshot,
    request_handoff,
};

const EffectsCapture = struct {
    events: [2]EffectEvent = undefined,
    event_count: usize = 0,
    forgotten_workspace: ?schema.WorkspaceLocation = null,
    snapshot_workspace: ?schema.WorkspaceLocation = null,
    handoff_workspace: ?schema.WorkspaceId = null,
    fail_snapshot: bool = false,
    fail_handoff: bool = false,

    fn port(capture: *EffectsCapture) Effects {
        return .{
            .context = capture,
            .forget_workspace = forgetWorkspace,
            .request_snapshot = requestSnapshot,
            .request_handoff = requestHandoff,
        };
    }

    fn handler(capture: *EffectsCapture) HandleResyncRequiredHandler {
        return .{ .effects = capture.port() };
    }

    fn record(capture: *EffectsCapture, event: EffectEvent) void {
        capture.events[capture.event_count] = event;
        capture.event_count += 1;
    }

    fn forgetWorkspace(context: *anyopaque, workspace: schema.WorkspaceLocation) void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.record(.forget_workspace);
        capture.forgotten_workspace = workspace;
    }

    fn requestSnapshot(context: *anyopaque, workspace: schema.WorkspaceLocation) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.record(.request_snapshot);
        capture.snapshot_workspace = workspace;

        if (capture.fail_snapshot) {
            return error.SnapshotRequestFailed;
        }
    }

    fn requestHandoff(context: *anyopaque, workspace: schema.WorkspaceId) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.record(.request_handoff);
        capture.handoff_workspace = workspace;

        if (capture.fail_handoff) {
            return error.HandoffRequestFailed;
        }
    }
};

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
