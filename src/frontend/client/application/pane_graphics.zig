//! Application use case for reconciling runtime pane graphics.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../model.zig");

const schema = core.schema;

pub const Command = union(enum) {
    snapshot: schema.graphics.Snapshot,
    image: schema.graphics.Image,
    shared_image: schema.graphics.SharedImage,
    image_chunk: schema.graphics.ImageChunk,
    placement: schema.graphics.Placement,
    delete_image: schema.graphics.DeleteImage,
    delete_placement: schema.graphics.DeletePlacement,

    /// Returns the pane identity carried by every graphics command.
    ///
    /// ```zig
    /// const pane_id = command.paneId();
    /// ```
    pub fn paneId(command: Command) schema.PaneId {
        return switch (command) {
            inline else => |value| value.pane_id,
        };
    }
};

pub const ResourceState = struct {
    pane_id: schema.PaneId,
    has_graphics: bool,
};

pub const ResourceResult = union(enum) {
    unchanged,
    changed: ResourceState,
    resync_required: schema.PaneId,
    shared_mapping_failed: schema.PaneId,
};

pub const Effects = struct {
    context: *anyopaque,
    apply: *const fn (*anyopaque, Command) anyerror!ResourceResult,
    request_snapshot: *const fn (*anyopaque, schema.PaneId) anyerror!void,
    disable_shared: *const fn (*anyopaque) anyerror!void,
};

pub const Applied = struct {
    pane_id: schema.PaneId,
    fallback: ?client_model.PaneGraphicsFallbackCommit,
};

pub const Outcome = union(enum) {
    unchanged,
    applied: Applied,
    resync_requested: schema.PaneId,
    shared_disabled: schema.PaneId,
};

pub const ReconcilePaneGraphicsHandler = struct {
    model: *client_model.Model,
    fallback_required: bool,
    effects: Effects,

    /// Reconciles one physical resource result, then commits its derived cell
    /// fallback or performs bounded recovery. Presentation observes versions.
    ///
    /// ```zig
    /// const outcome = try handler.execute(command);
    /// ```
    pub fn execute(handler: *ReconcilePaneGraphicsHandler, command: Command) !Outcome {
        const pane_id = command.paneId();
        const resource = try handler.effects.apply(handler.effects.context, command);

        return switch (resource) {
            .unchanged => .unchanged,
            .changed => |state| block: {
                if (state.pane_id != pane_id) {
                    return error.InvalidPaneGraphicsResult;
                }

                break :block .{ .applied = .{
                    .pane_id = pane_id,
                    .fallback = handler.model.setPaneGraphicsFallback(
                        pane_id,
                        handler.fallback_required and state.has_graphics,
                    ),
                } };
            },
            .resync_required => |recovery_pane| block: {
                if (recovery_pane != pane_id) {
                    return error.InvalidPaneGraphicsResult;
                }

                try handler.effects.request_snapshot(handler.effects.context, pane_id);
                break :block .{ .resync_requested = pane_id };
            },
            .shared_mapping_failed => |recovery_pane| block: {
                if (recovery_pane != pane_id) {
                    return error.InvalidPaneGraphicsResult;
                }

                try handler.effects.disable_shared(handler.effects.context);
                try handler.effects.request_snapshot(handler.effects.context, pane_id);
                break :block .{ .shared_disabled = pane_id };
            },
        };
    }
};

const EffectEvent = enum {
    apply,
    disable_shared,
    request_snapshot,
};

const EffectsCapture = struct {
    model: *const client_model.Model,
    result: ResourceResult,
    events: [3]EffectEvent = undefined,
    event_count: usize = 0,
    applied_before_commit: bool = false,
    fail_snapshot: bool = false,

    fn port(capture: *EffectsCapture) Effects {
        return .{
            .context = capture,
            .apply = apply,
            .request_snapshot = requestSnapshot,
            .disable_shared = disableShared,
        };
    }

    fn record(capture: *EffectsCapture, event: EffectEvent) void {
        capture.events[capture.event_count] = event;
        capture.event_count += 1;
    }

    fn apply(context: *anyopaque, command: Command) !ResourceResult {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        _ = command;
        capture.record(.apply);
        capture.applied_before_commit = capture.model.version().pane_graphics == 0;

        return capture.result;
    }

    fn requestSnapshot(context: *anyopaque, pane_id: schema.PaneId) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        _ = pane_id;
        capture.record(.request_snapshot);

        if (capture.fail_snapshot) {
            return error.SnapshotRequestFailed;
        }
    }

    fn disableShared(context: *anyopaque) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.record(.disable_shared);
    }
};

const TestingModel = struct {
    model: *client_model.Model,
    pane_id: schema.PaneId,

    fn init() !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();
        const pane_id: schema.PaneId = @enumFromInt(1);
        try model.workspace.bootstrap(pane_id, .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        }, .{ .cols = 2, .rows = 2 });

        return .{ .model = model, .pane_id = pane_id };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }

    fn command(testing: *const TestingModel) Command {
        return .{ .snapshot = .{
            .pane_id = testing.pane_id,
            .revision = 1,
            .phase = .begin,
        } };
    }
};

test "pane graphics commits fallback after physical resource application" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .result = .{ .changed = .{ .pane_id = testing.pane_id, .has_graphics = true } },
    };
    var handler: ReconcilePaneGraphicsHandler = .{
        .model = testing.model,
        .fallback_required = true,
        .effects = capture.port(),
    };

    const outcome = try handler.execute(testing.command());

    try std.testing.expect(capture.applied_before_commit);
    try std.testing.expectEqualSlices(EffectEvent, &.{.apply}, capture.events[0..capture.event_count]);
    try std.testing.expect(outcome == .applied);
    try std.testing.expect(outcome.applied.fallback != null);
    try std.testing.expectEqualDeep(client_model.Version{ .pane_graphics = 1 }, testing.model.version());
}

test "pane graphics stale resource result has no semantic or recovery effects" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{ .model = testing.model, .result = .unchanged };
    var handler: ReconcilePaneGraphicsHandler = .{
        .model = testing.model,
        .fallback_required = true,
        .effects = capture.port(),
    };

    const outcome = try handler.execute(testing.command());

    try std.testing.expect(outcome == .unchanged);
    try std.testing.expectEqualSlices(EffectEvent, &.{.apply}, capture.events[0..capture.event_count]);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "pane graphics revision break requests a snapshot after resource application" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .result = .{ .resync_required = testing.pane_id },
    };
    var handler: ReconcilePaneGraphicsHandler = .{
        .model = testing.model,
        .fallback_required = true,
        .effects = capture.port(),
    };

    const outcome = try handler.execute(testing.command());

    try std.testing.expect(outcome == .resync_requested);
    try std.testing.expectEqualSlices(
        EffectEvent,
        &.{ .apply, .request_snapshot },
        capture.events[0..capture.event_count],
    );
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "shared graphics failure disables mapping before requesting a snapshot" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .result = .{ .shared_mapping_failed = testing.pane_id },
    };
    var handler: ReconcilePaneGraphicsHandler = .{
        .model = testing.model,
        .fallback_required = false,
        .effects = capture.port(),
    };

    const outcome = try handler.execute(testing.command());

    try std.testing.expect(outcome == .shared_disabled);
    try std.testing.expectEqualSlices(
        EffectEvent,
        &.{ .apply, .disable_shared, .request_snapshot },
        capture.events[0..capture.event_count],
    );
}

test "shared graphics recovery preserves downgrade when snapshot enqueue fails" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .result = .{ .shared_mapping_failed = testing.pane_id },
        .fail_snapshot = true,
    };
    var handler: ReconcilePaneGraphicsHandler = .{
        .model = testing.model,
        .fallback_required = false,
        .effects = capture.port(),
    };

    try std.testing.expectError(error.SnapshotRequestFailed, handler.execute(testing.command()));

    try std.testing.expectEqualSlices(
        EffectEvent,
        &.{ .apply, .disable_shared, .request_snapshot },
        capture.events[0..capture.event_count],
    );
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}
