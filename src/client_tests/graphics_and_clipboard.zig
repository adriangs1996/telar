//! Client integration tests for graphics and clipboard. Graphics tests put
//! the shared resource store behind the client's graphics port, since
//! revisions, shared mappings and fallbacks are that store's decisions.
const data = @import("model");
const core = @import("telar-core");
const ClientHarness = @import("ClientHarness.zig");
const fixtures = @import("fixtures.zig");
const std = @import("std");
const client_module = @import("telar-client");

test "a graphics revision break requests a graphics snapshot" {
    var pixels: PixelStore = .init(std.testing.allocator);
    defer pixels.deinit();
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    harness.client.graphics = pixelRetention(&pixels);
    const client = harness.client;

    var payload: [256]u8 = undefined;
    const begin = try core.encodeGraphicsSnapshot(&payload, .{
        .pane_id = ClientHarness.bootstrap_pane,
        .revision = 8,
        .phase = .begin,
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(begin));
    const image = try core.encodeGraphicsImage(&payload, .{
        .pane_id = ClientHarness.bootstrap_pane,
        .revision = 9,
        .image = .{
            .key = .{ .image_id = 1, .generation = 1 },
            .format = .rgb,
            .width = 1,
            .height = 1,
            .byte_len = 3,
        },
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(image));
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .request_graphics_snapshot);
}

test "pane graphics commit their cell fallback before presenter observation" {
    var pixels: PixelStore = .init(std.testing.allocator);
    defer pixels.deinit();
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    harness.client.graphics = pixelRetention(&pixels);
    try harness.bootstrap();
    const client = harness.client;
    var capabilities = client.model.host.host_capabilities;
    capabilities.images = .unsupported;
    try fixtures.reconcileCapabilities(&client.model, capabilities);
    const version_before = client.model.version();
    const observed_before = client.presentation.observed;

    var payload: [256]u8 = undefined;
    const encoded = try core.encodeGraphicsImage(&payload, .{
        .pane_id = ClientHarness.bootstrap_pane,
        .revision = 1,
        .image = .{
            .key = .{ .image_id = 1, .generation = 1 },
            .format = .rgb,
            .width = 1,
            .height = 1,
            .byte_len = 3,
        },
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(encoded));

    var committed = version_before;
    committed.pane_graphics += 1;
    try std.testing.expectEqualDeep(committed, client.model.version());
    try std.testing.expect(client.model.panes.find(ClientHarness.bootstrap_pane).?.graphics_placeholder);
    try std.testing.expectEqualDeep(observed_before, client.presentation.observed);

    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(committed, client.presentation.prepared.model);
}

test "presenter observes physical graphics without a semantic fallback" {
    var pixels: PixelStore = .init(std.testing.allocator);
    defer pixels.deinit();
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    harness.client.graphics = pixelRetention(&pixels);
    try harness.bootstrap();
    const client = harness.client;
    var capabilities = client.model.host.host_capabilities;
    capabilities.images = .supported;
    try fixtures.reconcileCapabilities(&client.model, capabilities);
    const version_before = client.model.version();

    var payload: [256]u8 = undefined;
    const encoded = try core.encodeGraphicsImage(&payload, .{
        .pane_id = ClientHarness.bootstrap_pane,
        .revision = 5,
        .image = .{
            .key = .{ .image_id = 1, .generation = 1 },
            .format = .rgb,
            .width = 1,
            .height = 1,
            .byte_len = 3,
        },
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(encoded));

    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(@as(u64, 1), pixels.ingressVersion());
    try std.testing.expect(!client.model.panes.find(ClientHarness.bootstrap_pane).?.graphics_placeholder);

    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(version_before, client.presentation.prepared.model);

    const stale = try core.encodeGraphicsDeleteImage(&payload, .{
        .pane_id = ClientHarness.bootstrap_pane,
        .revision = 4,
        .key = .{ .image_id = 1, .generation = 1 },
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(stale));

    try std.testing.expectEqual(@as(u64, 1), pixels.ingressVersion());
    try std.testing.expectEqualDeep(version_before, client.model.version());
}

test "shared graphics mapping failure downgrades before resynchronizing" {
    var pixels: PixelStore = .init(std.testing.allocator);
    defer pixels.deinit();
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    harness.client.graphics = pixelRetention(&pixels);
    try harness.bootstrap();
    const client = harness.client;
    const version_before = client.model.version();

    var payload: [256]u8 = undefined;
    const encoded = try core.encodeGraphicsSharedImage(&payload, .{
        .pane_id = ClientHarness.bootstrap_pane,
        .revision = 1,
        .image = .{
            .key = .{ .image_id = 1, .generation = 1 },
            .format = .rgb,
            .width = 1,
            .height = 1,
            .byte_len = 3,
        },
        .name = try core.ShmName.init("/telar-missing"),
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(encoded));
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const downgrade = try harness.nextClientMessage(&buffer);
    const recovery = try harness.nextClientMessage(&buffer);
    try std.testing.expect(downgrade == .configure_graphics);
    try std.testing.expect(!downgrade.configure_graphics.shared);
    try std.testing.expect(recovery == .request_graphics_snapshot);
    try std.testing.expectEqual(ClientHarness.bootstrap_pane, recovery.request_graphics_snapshot.pane_id);
    try std.testing.expectEqual(@as(u64, 0), pixels.ingressVersion());
    try std.testing.expectEqualDeep(version_before, client.model.version());
}

test "runtime stopping and stray history results" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();

    var payload: [128]u8 = undefined;
    const stopping = try core.encodeRuntimeStopping(&payload);
    try std.testing.expectEqual(
        @as(?u8, 0),
        try client_module.runtime_messages.handleServerMessage(harness.client, try core.decodeServer(stopping)),
    );

    const history = try core.encodeHistoryResults(&payload, .{
        .request_id = @enumFromInt(2),
        .entries = &.{},
    });
    try std.testing.expectEqual(
        @as(?u8, null),
        try client_module.runtime_messages.handleServerMessage(harness.client, try core.decodeServer(history)),
    );
    try std.testing.expectEqual(@as(u8, 0), harness.client.model.history_palette.len);

    const suggestion = try core.encodeCommandSuggestion(&payload, .{
        .request_id = @enumFromInt(3),
        .status = .ready,
        .text = "ls -la",
    });
    try std.testing.expectEqual(
        @as(?u8, null),
        try client_module.runtime_messages.handleServerMessage(harness.client, try core.decodeServer(suggestion)),
    );
    try std.testing.expectEqual(@as(u16, 0), harness.client.model.suggestion.text_len);
}

test "a pane clipboard write reaches the host terminal" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();

    const before = harness.recordedEffects().len;
    var payload: [128]u8 = undefined;
    const clipboard = try core.encodePaneClipboard(&payload, .{
        .pane_id = ClientHarness.bootstrap_pane,
        .bytes = "copied",
    });
    _ = try client_module.runtime_messages.handleServerMessage(harness.client, try core.decodeServer(clipboard));
    try harness.deliverHostEffects();

    const effects = harness.recordedEffects()[before..];
    try std.testing.expectEqual(@as(usize, 1), effects.len);
    try std.testing.expect(effects[0] == .clipboard);
}

test "an invalid pane clipboard writes no host bytes" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const before = harness.recordedEffects().len;

    try std.testing.expectError(error.UnexpectedPane, client_module.runtime_messages.handleServerMessage(
        harness.client,
        .{
            .pane_clipboard = .{
                .pane_id = .invalid,
                .bytes = "rejected",
            },
        },
    ));
    try harness.deliverHostEffects();

    try std.testing.expectEqual(before, harness.recordedEffects().len);
}

const PixelStore = client_module.GenericResourceStore(PixelDelivery);

/// Delivery for a store whose images reach no host: nothing is leased, so
/// every image can be released at once.
const PixelDelivery = struct {
    pub const State = struct {};
    pub const ImageState = struct {};
    pub const PlacementState = struct {};

    pub fn imageCreated(_: *PixelStore) !ImageState {
        return .{};
    }

    pub fn placementCreated(_: *PixelStore) !PlacementState {
        return .{};
    }

    pub fn releaseImage(_: *PixelStore, _: *PixelStore.ImageEntry) void {}

    pub fn imageDeleted(_: *PixelStore, _: PixelStore.ImageEntry) void {}

    pub fn placementDeleted(_: *PixelStore, _: PixelStore.PlacementEntry) void {}

    pub fn placementChanged(_: *PixelStore, _: client_module.PlacementIdentity, _: *PixelStore.PlacementEntry) void {}

    pub fn placementVisibility(_: *PixelStore, _: *PixelStore.PlacementEntry, _: bool) void {}

    pub fn canRelease(_: *PixelStore, _: client_module.ImageIdentity, _: *const PixelStore.ImageEntry) bool {
        return true;
    }

    pub fn deinit(_: *PixelStore) void {}
};

fn pixelRetention(store: *PixelStore) client_module.GraphicsRetention {
    return .{
        .context = store,
        .apply_fn = applyPixels,
        .clear_pane_fn = clearPanePixels,
        .set_pane_visible_fn = setPanePixelsVisible,
        .pane_visible_fn = panePixelsVisible,
        .has_pane_graphics_fn = hasPanePixels,
        .ingress_version_fn = pixelIngressVersion,
        .peek_credit_fn = peekPixelCredit,
        .consume_credit_fn = consumePixelCredit,
    };
}

fn pixelStore(context: *anyopaque) *PixelStore {
    return @ptrCast(@alignCast(context));
}

fn applyPixels(context: *anyopaque, command: data.PaneGraphicsCommand) anyerror!void {
    const store = pixelStore(context);

    return switch (command) {
        .snapshot => |message| store.applySnapshot(message),
        .image => |message| store.applyImage(message),
        .shared_image => |message| store.applySharedImage(message),
        .image_chunk => |message| store.applyChunk(message),
        .placement => |message| store.applyPlacement(message),
        .delete_image => |message| store.deleteImage(message),
        .delete_placement => |message| store.deletePlacement(message),
    };
}

fn clearPanePixels(context: *anyopaque, pane_id: core.PaneId) void {
    pixelStore(context).clearPane(pane_id);
}

fn setPanePixelsVisible(context: *anyopaque, pane_id: core.PaneId, visible: bool) anyerror!void {
    try pixelStore(context).setPaneVisible(pane_id, visible);
}

fn panePixelsVisible(context: *anyopaque, pane_id: core.PaneId) bool {
    return pixelStore(context).paneVisible(pane_id);
}

fn hasPanePixels(context: *anyopaque, pane_id: core.PaneId) bool {
    return pixelStore(context).hasPaneGraphics(pane_id);
}

fn pixelIngressVersion(context: *anyopaque) u64 {
    return pixelStore(context).ingressVersion();
}

fn peekPixelCredit(context: *anyopaque) ?client_module.GraphicsCredit {
    return pixelStore(context).peekCredit();
}

fn consumePixelCredit(context: *anyopaque, credit: client_module.GraphicsCredit) void {
    pixelStore(context).consumeCredit(credit);
}
