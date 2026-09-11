//! Application use case for reconciling runtime pane graphics.

const SnapshotType = @import("telar-core").Snapshot;
const ImageType = @import("telar-core").SchemaImage;
const SharedImageType = @import("telar-core").SharedImage;
const ImageChunkType = @import("telar-core").ImageChunk;
const PlacementType = @import("telar-core").SchemaPlacement;
const DeleteImageType = @import("telar-core").DeleteImage;
const DeletePlacementType = @import("telar-core").DeletePlacement;
const PaneIdType = @import("telar-core").PaneId;
const ResourceState = @import("ResourceState.zig");
const Applied = @import("Applied.zig");
const FallbackTestingModel = @import("FallbackTestingModel.zig");
const FallbackCapture = @import("FallbackCapture.zig");
const SyncPaneGraphicsFallbacksHandler = @import("SyncPaneGraphicsFallbacksHandler.zig");
const std = @import("std");
const VersionType = @import("../../model/Version.zig");
const PaneGraphicsTestingModel = @import("PaneGraphicsTestingModel.zig");
const PaneGraphicsEffectsCapture = @import("PaneGraphicsEffectsCapture.zig");
const ReconcilePaneGraphicsHandler = @import("ReconcilePaneGraphicsHandler.zig");

pub const Command = union(enum) {
    snapshot: SnapshotType,
    image: ImageType,
    shared_image: SharedImageType,
    image_chunk: ImageChunkType,
    placement: PlacementType,
    delete_image: DeleteImageType,
    delete_placement: DeletePlacementType,

    /// Returns the pane identity carried by every graphics command.
    ///
    /// ```zig
    /// const pane_id = command.paneId();
    /// ```
    pub fn paneId(command: Command) PaneIdType {
        return switch (command) {
            inline else => |value| value.pane_id,
        };
    }
};

pub const ResourceResult = union(enum) {
    unchanged,
    changed: ResourceState,
    resync_required: PaneIdType,
    shared_mapping_failed: PaneIdType,
};

pub const Outcome = union(enum) {
    unchanged,
    applied: Applied,
    resync_requested: PaneIdType,
    shared_disabled: PaneIdType,
};

pub const EffectEvent = enum {
    apply,
    disable_shared,
    request_snapshot,
};

test "pane graphics fallback sync derives every bounded pane from physical resources" {
    var testing = try FallbackTestingModel.init();
    defer testing.deinit();
    const with_graphics = [_]PaneIdType{ testing.first, testing.third };
    var capture: FallbackCapture = .{ .with_graphics = &with_graphics };
    var handler: SyncPaneGraphicsFallbacksHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    handler.execute();

    try std.testing.expectEqualSlices(
        PaneIdType,
        &.{ testing.first, testing.second, testing.third },
        capture.queries[0..capture.query_count],
    );
    try std.testing.expect(testing.model.workspace.findPane(testing.first).?.graphics_placeholder);
    try std.testing.expect(!testing.model.workspace.findPane(testing.second).?.graphics_placeholder);
    try std.testing.expect(testing.model.workspace.findPane(testing.third).?.graphics_placeholder);
    try std.testing.expectEqual(VersionType{ .pane_graphics = 2 }, testing.model.version());
}

test "pane graphics fallback sync suppresses repeats" {
    var testing = try FallbackTestingModel.init();
    defer testing.deinit();
    const with_graphics = [_]PaneIdType{testing.second};
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
    _ = (try testing.model.observeHostCapability(.{ .images = .supported })).?;
    const version = testing.model.version();
    const with_graphics = [_]PaneIdType{ testing.first, testing.second, testing.third };
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
    var testing = try PaneGraphicsTestingModel.init();
    defer testing.deinit();
    var capture: PaneGraphicsEffectsCapture = .{
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
    try std.testing.expectEqualDeep(VersionType{ .pane_graphics = 1 }, testing.model.version());
}

test "pane graphics derives fallback from committed host support" {
    var testing = try PaneGraphicsTestingModel.init();
    defer testing.deinit();
    _ = (try testing.model.observeHostCapability(.{ .images = .supported })).?;
    var capture: PaneGraphicsEffectsCapture = .{
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
    try std.testing.expectEqualDeep(VersionType{ .host_capabilities = 1 }, testing.model.version());
}

test "pane graphics stale resource result has no semantic or recovery effects" {
    var testing = try PaneGraphicsTestingModel.init();
    defer testing.deinit();
    var capture: PaneGraphicsEffectsCapture = .{ .model = testing.model, .result = .unchanged };
    var handler: ReconcilePaneGraphicsHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    const outcome = try handler.execute(testing.command());

    try std.testing.expect(outcome == .unchanged);
    try std.testing.expectEqualSlices(EffectEvent, &.{.apply}, capture.events[0..capture.event_count]);
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "pane graphics revision break requests a snapshot after resource application" {
    var testing = try PaneGraphicsTestingModel.init();
    defer testing.deinit();
    var capture: PaneGraphicsEffectsCapture = .{
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
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "shared graphics failure disables mapping before requesting a snapshot" {
    var testing = try PaneGraphicsTestingModel.init();
    defer testing.deinit();
    var capture: PaneGraphicsEffectsCapture = .{
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
    var testing = try PaneGraphicsTestingModel.init();
    defer testing.deinit();
    var capture: PaneGraphicsEffectsCapture = .{
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
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}
