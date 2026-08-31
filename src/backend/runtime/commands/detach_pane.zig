//! Application command for removing one pane from a client session.

const std = @import("std");
const core = @import("telar-core");
const attachment_mod = @import("../attachment/root.zig");

const schema = core.schema;

pub const DetachPane = struct {
    pane_id: schema.PaneId,
};

pub const DetachPaneResult = enum {
    detached,
    not_attached,
};

pub const Attachments = struct {
    context: *anyopaque,
    detach: *const fn (*anyopaque, schema.PaneId) ?attachment_mod.PaneDetached,
    leave_workspace: *const fn (*anyopaque, schema.WorkspaceLocation) bool,
};

pub const GeometryLease = struct {
    context: *anyopaque,
    release: *const fn (*anyopaque, schema.WorkspaceLocation) void,
};

pub const DetachPaneExecutor = struct {
    context: *anyopaque,
    execute_fn: *const fn (*anyopaque, DetachPane) anyerror!DetachPaneResult,

    /// Executes pane detachment through the bound application handler.
    ///
    /// ```zig
    /// const result = try executor.execute(.{ .pane_id = pane_id });
    /// ```
    pub fn execute(executor: DetachPaneExecutor, command: DetachPane) !DetachPaneResult {
        return executor.execute_fn(executor.context, command);
    }
};

pub const DetachPaneHandler = struct {
    attachments: Attachments,
    geometry: GeometryLease,

    /// Commits attachment removal, ends empty-workspace observation, then
    /// releases its geometry. Missing attachments have no effect.
    ///
    /// ```zig
    /// const result = try handler.execute(.{ .pane_id = pane_id });
    /// ```
    pub fn execute(handler: *DetachPaneHandler, command: DetachPane) !DetachPaneResult {
        const detached = handler.attachments.detach(handler.attachments.context, command.pane_id) orelse return .not_attached;
        std.debug.assert(detached.pane_id == command.pane_id);

        if (detached.last_attachment) {
            const left_workspace = handler.attachments.leave_workspace(handler.attachments.context, detached.workspace);

            if (!left_workspace) {
                return error.AttachmentStateConflict;
            }

            handler.geometry.release(handler.geometry.context, detached.workspace);
        }

        return .detached;
    }

    /// Exposes this handler through the command interface used by controllers.
    ///
    /// ```zig
    /// const executor = handler.executor();
    /// ```
    pub fn executor(handler: *DetachPaneHandler) DetachPaneExecutor {
        return .{ .context = handler, .execute_fn = executeErased };
    }

    fn executeErased(context: *anyopaque, command: DetachPane) !DetachPaneResult {
        const handler: *DetachPaneHandler = @ptrCast(@alignCast(context));
        return handler.execute(command);
    }
};

const Effect = enum {
    detach,
    leave_workspace,
    release,
};

const Capture = struct {
    detached: ?attachment_mod.PaneDetached = null,
    effects: [3]Effect = undefined,
    effect_count: usize = 0,
    requested_pane: schema.PaneId = .invalid,
    released_workspace: ?schema.WorkspaceLocation = null,
    leave_allowed: bool = true,

    fn attachments(capture: *Capture) Attachments {
        return .{
            .context = capture,
            .detach = detach,
            .leave_workspace = leaveWorkspace,
        };
    }

    fn geometry(capture: *Capture) GeometryLease {
        return .{ .context = capture, .release = release };
    }

    fn detach(context: *anyopaque, pane_id: schema.PaneId) ?attachment_mod.PaneDetached {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.record(.detach);
        capture.requested_pane = pane_id;
        return capture.detached;
    }

    fn release(context: *anyopaque, workspace: schema.WorkspaceLocation) void {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.record(.release);
        capture.released_workspace = workspace;
    }

    fn leaveWorkspace(context: *anyopaque, workspace: schema.WorkspaceLocation) bool {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.record(.leave_workspace);
        return capture.leave_allowed and capture.detached != null and std.meta.eql(capture.detached.?.workspace, workspace);
    }

    fn record(capture: *Capture, effect: Effect) void {
        capture.effects[capture.effect_count] = effect;
        capture.effect_count += 1;
    }
};

fn testingDetached(last_attachment: bool) !attachment_mod.PaneDetached {
    return .{
        .pane_id = try schema.id.pane(7),
        .workspace = .{ .workspace = try schema.id.workspace(3) },
        .last_attachment = last_attachment,
    };
}

test "DetachPaneHandler leaves missing attachments and geometry unchanged" {
    var capture: Capture = .{};
    var handler: DetachPaneHandler = .{
        .attachments = capture.attachments(),
        .geometry = capture.geometry(),
    };
    const pane_id = try schema.id.pane(7);

    const result = try handler.execute(.{ .pane_id = pane_id });

    try std.testing.expectEqual(DetachPaneResult.not_attached, result);
    try std.testing.expectEqual(pane_id, capture.requested_pane);
    try std.testing.expectEqual(@as(usize, 1), capture.effect_count);
    try std.testing.expectEqual(Effect.detach, capture.effects[0]);
    try std.testing.expect(capture.released_workspace == null);
}

test "DetachPaneHandler keeps geometry while another pane observes the workspace" {
    var capture: Capture = .{ .detached = try testingDetached(false) };
    var handler: DetachPaneHandler = .{
        .attachments = capture.attachments(),
        .geometry = capture.geometry(),
    };

    const result = try handler.execute(.{ .pane_id = capture.detached.?.pane_id });

    try std.testing.expectEqual(DetachPaneResult.detached, result);
    try std.testing.expectEqual(@as(usize, 1), capture.effect_count);
    try std.testing.expect(capture.released_workspace == null);
}

test "DetachPaneHandler releases geometry after leaving the workspace" {
    var capture: Capture = .{ .detached = try testingDetached(true) };
    var handler: DetachPaneHandler = .{
        .attachments = capture.attachments(),
        .geometry = capture.geometry(),
    };

    const result = try handler.execute(.{ .pane_id = capture.detached.?.pane_id });

    try std.testing.expectEqual(DetachPaneResult.detached, result);
    try std.testing.expectEqual(@as(usize, 3), capture.effect_count);
    try std.testing.expectEqual(Effect.detach, capture.effects[0]);
    try std.testing.expectEqual(Effect.leave_workspace, capture.effects[1]);
    try std.testing.expectEqual(Effect.release, capture.effects[2]);
    try std.testing.expectEqualDeep(capture.detached.?.workspace, capture.released_workspace.?);
}

test "DetachPaneHandler does not release geometry after a workspace state conflict" {
    var capture: Capture = .{
        .detached = try testingDetached(true),
        .leave_allowed = false,
    };
    var handler: DetachPaneHandler = .{
        .attachments = capture.attachments(),
        .geometry = capture.geometry(),
    };

    try std.testing.expectError(error.AttachmentStateConflict, handler.execute(.{
        .pane_id = capture.detached.?.pane_id,
    }));

    try std.testing.expectEqual(@as(usize, 2), capture.effect_count);
    try std.testing.expectEqual(Effect.detach, capture.effects[0]);
    try std.testing.expectEqual(Effect.leave_workspace, capture.effects[1]);
    try std.testing.expect(capture.released_workspace == null);
}
