//! Application use case for reconciling runtime pane graphics.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../model/root.zig");

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

pub const FallbackEffects = struct {
    context: *anyopaque,
    has_graphics: *const fn (*anyopaque, schema.PaneId) bool,
};

pub const ReconcilePaneGraphicsHandler = struct {
    model: *client_model.Model,
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
                        handler.model.hostCapabilities().kitty_graphics != .supported and
                            state.has_graphics,
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

pub const SyncPaneGraphicsFallbacksHandler = struct {
    model: *client_model.Model,
    effects: FallbackEffects,

    /// Reconciles every bounded pane fallback from committed host capability
    /// state and the physical graphics owned by the client adapter.
    ///
    /// ```zig
    /// handler.execute();
    /// ```
    pub fn execute(handler: *SyncPaneGraphicsFallbacksHandler) void {
        const fallback_required = handler.model.hostCapabilities().kitty_graphics != .supported;
        var inspected: usize = 0;
        var tabs = handler.model.workspace.tabIterator();
        while (tabs.next()) |tab| {
            var panes = tab.model.paneIterator();
            while (panes.next()) |pane| {
                inspected += 1;
                const has_graphics = fallback_required and
                    handler.effects.has_graphics(handler.effects.context, pane.id);
                _ = handler.model.setPaneGraphicsFallback(pane.id, has_graphics);
            }
        }

        std.debug.assert(inspected <= schema.max_tabs_per_workspace * schema.max_panes_per_tab);
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
        try model.workspace.bootstrap(.{ .pane_id = pane_id, .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        }, .size = .{ .cols = 2, .rows = 2 } });

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

const FallbackTestingModel = struct {
    model: *client_model.Model,
    first: schema.PaneId,
    second: schema.PaneId,
    third: schema.PaneId,

    fn init() !FallbackTestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();

        const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
        const first_location: schema.TabLocation = .{
            .workspace = workspace,
            .tab_id = @enumFromInt(1),
        };
        const second_location: schema.TabLocation = .{
            .workspace = workspace,
            .tab_id = @enumFromInt(2),
        };
        const first: schema.PaneId = @enumFromInt(1);
        const second: schema.PaneId = @enumFromInt(2);
        const third: schema.PaneId = @enumFromInt(3);
        try model.workspace.bootstrap(.{ .pane_id = first, .location = first_location, .size = .{ .cols = 20, .rows = 5 } });
        try model.workspace.active().?.model.split(.{ .existing_pane = first, .new_pane = second, .location = first_location, .axis = .horizontal, .area = .{ .w = 20, .h = 5 } });
        _ = try model.workspace.addCreated(.{
            .location = second_location,
            .position = 1,
            .label = "logs",
            .root_pane_id = third,
        }, .{ .cols = 20, .rows = 5 });

        return .{
            .model = model,
            .first = first,
            .second = second,
            .third = third,
        };
    }

    fn deinit(testing: *FallbackTestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }
};

const FallbackCapture = struct {
    with_graphics: []const schema.PaneId,
    queries: [3]schema.PaneId = undefined,
    query_count: usize = 0,

    fn port(capture: *FallbackCapture) FallbackEffects {
        return .{ .context = capture, .has_graphics = hasGraphics };
    }

    fn hasGraphics(context: *anyopaque, pane_id: schema.PaneId) bool {
        const capture: *FallbackCapture = @ptrCast(@alignCast(context));
        capture.queries[capture.query_count] = pane_id;
        capture.query_count += 1;

        return std.mem.findScalar(schema.PaneId, capture.with_graphics, pane_id) != null;
    }
};

test "pane graphics fallback sync derives every bounded pane from physical resources" {
    var testing = try FallbackTestingModel.init();
    defer testing.deinit();
    const with_graphics = [_]schema.PaneId{ testing.first, testing.third };
    var capture: FallbackCapture = .{ .with_graphics = &with_graphics };
    var handler: SyncPaneGraphicsFallbacksHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    handler.execute();

    try std.testing.expectEqualSlices(
        schema.PaneId,
        &.{ testing.first, testing.second, testing.third },
        capture.queries[0..capture.query_count],
    );
    try std.testing.expect(testing.model.workspace.findPane(testing.first).?.graphics_placeholder);
    try std.testing.expect(!testing.model.workspace.findPane(testing.second).?.graphics_placeholder);
    try std.testing.expect(testing.model.workspace.findPane(testing.third).?.graphics_placeholder);
    try std.testing.expectEqual(client_model.Version{ .pane_graphics = 2 }, testing.model.version());
}

test "pane graphics fallback sync suppresses repeats" {
    var testing = try FallbackTestingModel.init();
    defer testing.deinit();
    const with_graphics = [_]schema.PaneId{testing.second};
    var capture: FallbackCapture = .{ .with_graphics = &with_graphics };
    var handler: SyncPaneGraphicsFallbacksHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    handler.execute();
    const version = testing.model.version();
    capture.query_count = 0;

    handler.execute();

    try std.testing.expectEqual(@as(usize, 3), capture.query_count);
    try std.testing.expectEqualDeep(version, testing.model.version());
}

test "supported pane graphics clears fallbacks without querying physical resources" {
    var testing = try FallbackTestingModel.init();
    defer testing.deinit();
    _ = testing.model.setPaneGraphicsFallback(testing.first, true).?;
    _ = testing.model.setPaneGraphicsFallback(testing.second, true).?;
    _ = testing.model.setPaneGraphicsFallback(testing.third, true).?;
    _ = (try testing.model.observeHostCapability(.{ .kitty_graphics = .supported })).?;
    const version = testing.model.version();
    const with_graphics = [_]schema.PaneId{ testing.first, testing.second, testing.third };
    var capture: FallbackCapture = .{ .with_graphics = &with_graphics };
    var handler: SyncPaneGraphicsFallbacksHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    handler.execute();

    try std.testing.expectEqual(@as(usize, 0), capture.query_count);
    try std.testing.expect(!testing.model.workspace.findPane(testing.first).?.graphics_placeholder);
    try std.testing.expect(!testing.model.workspace.findPane(testing.second).?.graphics_placeholder);
    try std.testing.expect(!testing.model.workspace.findPane(testing.third).?.graphics_placeholder);
    try std.testing.expectEqual(version.pane_graphics + 3, testing.model.version().pane_graphics);
}

test "pane graphics commits fallback after physical resource application" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{
        .model = testing.model,
        .result = .{ .changed = .{ .pane_id = testing.pane_id, .has_graphics = true } },
    };
    var handler: ReconcilePaneGraphicsHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    const outcome = try handler.execute(testing.command());

    try std.testing.expect(capture.applied_before_commit);
    try std.testing.expectEqualSlices(EffectEvent, &.{.apply}, capture.events[0..capture.event_count]);
    try std.testing.expect(outcome == .applied);
    try std.testing.expect(outcome.applied.fallback != null);
    try std.testing.expectEqualDeep(client_model.Version{ .pane_graphics = 1 }, testing.model.version());
}

test "pane graphics derives fallback from committed host support" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    _ = (try testing.model.observeHostCapability(.{ .kitty_graphics = .supported })).?;
    var capture: EffectsCapture = .{
        .model = testing.model,
        .result = .{ .changed = .{ .pane_id = testing.pane_id, .has_graphics = true } },
    };
    var handler: ReconcilePaneGraphicsHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    const outcome = try handler.execute(testing.command());

    try std.testing.expect(outcome == .applied);
    try std.testing.expect(outcome.applied.fallback == null);
    try std.testing.expect(!testing.model.workspace.findPane(testing.pane_id).?.graphics_placeholder);
    try std.testing.expectEqualDeep(client_model.Version{ .host_capabilities = 1 }, testing.model.version());
}

test "pane graphics stale resource result has no semantic or recovery effects" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{ .model = testing.model, .result = .unchanged };
    var handler: ReconcilePaneGraphicsHandler = .{
        .model = testing.model,
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
