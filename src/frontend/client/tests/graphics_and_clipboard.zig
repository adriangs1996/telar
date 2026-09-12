//! Client integration tests for graphics and clipboard.

const TerminalClient = @import("../TerminalClient.zig");
const host = TerminalClient.of;
const TestHarness = @import("TestHarness.zig");
const encodeGraphicsSnapshot_module = @import("telar-core").encodeGraphicsSnapshot;
const server_messages = @import("telar-client").server_messages;
const decodeServer_module = @import("telar-core").decodeServer;
const encodeGraphicsImage_module = @import("telar-core").encodeGraphicsImage;
const std = @import("std");
const presentation_lifecycle = @import("../presentation/presentation_lifecycle.zig");
const encodeGraphicsDeleteImage_module = @import("telar-core").encodeGraphicsDeleteImage;
const encodeGraphicsSharedImage_module = @import("telar-core").encodeGraphicsSharedImage;
const ShmNameType = @import("telar-core").ShmName;
const encodeRuntimeStopping_module = @import("telar-core").encodeRuntimeStopping;
const encodeHistoryResults_module = @import("telar-core").encodeHistoryResults;
const encodeCommandSuggestion_module = @import("telar-core").encodeCommandSuggestion;
const encodePaneClipboard_module = @import("telar-core").encodePaneClipboard;
const pane_clipboards = @import("telar-client").controllers.pane_clipboards;

test "a graphics revision break requests a graphics snapshot" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;

    var payload: [256]u8 = undefined;
    const begin = try encodeGraphicsSnapshot_module(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .revision = 8,
        .phase = .begin,
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(begin));
    const image = try encodeGraphicsImage_module(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .revision = 9,
        .image = .{
            .key = .{ .image_id = 1, .generation = 1 },
            .format = .rgb,
            .width = 1,
            .height = 1,
            .byte_len = 3,
        },
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(image));
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .request_graphics_snapshot);
}

test "pane graphics commit their cell fallback before presenter observation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    _ = try client.model.observeHostCapability(.{ .images = .unsupported });
    const version_before = client.model.version();
    const pending_before = host(client).presenter.pending_updates;

    var payload: [256]u8 = undefined;
    const encoded = try encodeGraphicsImage_module(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .revision = 1,
        .image = .{
            .key = .{ .image_id = 1, .generation = 1 },
            .format = .rgb,
            .width = 1,
            .height = 1,
            .byte_len = 3,
        },
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(encoded));

    var committed = version_before;
    committed.pane_graphics += 1;
    try std.testing.expectEqualDeep(committed, client.model.version());
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.graphics_placeholder);
    try std.testing.expectEqual(pending_before, host(client).presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_before + 1, host(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(committed, host(client).presenter.presentation_state.prepared.model);
}

test "presenter observes physical graphics without a semantic fallback" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    _ = try client.model.observeHostCapability(.{ .images = .supported });
    const version_before = client.model.version();
    const pending_before = host(client).presenter.pending_updates;

    var payload: [256]u8 = undefined;
    const encoded = try encodeGraphicsImage_module(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .revision = 5,
        .image = .{
            .key = .{ .image_id = 1, .generation = 1 },
            .format = .rgb,
            .width = 1,
            .height = 1,
            .byte_len = 3,
        },
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(encoded));

    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(@as(u64, 1), host(client).graphics_store.ingressVersion());
    try std.testing.expectEqual(pending_before, host(client).presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_before + 1, host(client).presenter.pending_updates);
    try std.testing.expectEqual(@as(u64, 1), host(client).presenter.presentation_state.observed.graphics_ingress);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(@as(u64, 1), host(client).presenter.presentation_state.prepared.graphics_ingress);

    const pending_after = host(client).presenter.pending_updates;
    const stale = try encodeGraphicsDeleteImage_module(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .revision = 4,
        .key = .{ .image_id = 1, .generation = 1 },
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(stale));
    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(@as(u64, 1), host(client).graphics_store.ingressVersion());
    try std.testing.expectEqual(pending_after, host(client).presenter.pending_updates);
}

test "shared graphics mapping failure downgrades before resynchronizing" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before = client.model.version();

    var payload: [256]u8 = undefined;
    const encoded = try encodeGraphicsSharedImage_module(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .revision = 1,
        .image = .{
            .key = .{ .image_id = 1, .generation = 1 },
            .format = .rgb,
            .width = 1,
            .height = 1,
            .byte_len = 3,
        },
        .name = try ShmNameType.init("/telar-missing"),
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(encoded));
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const downgrade = try harness.nextClientMessage(&buffer);
    const recovery = try harness.nextClientMessage(&buffer);
    try std.testing.expect(downgrade == .configure_graphics);
    try std.testing.expect(!downgrade.configure_graphics.shared);
    try std.testing.expect(recovery == .request_graphics_snapshot);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, recovery.request_graphics_snapshot.pane_id);
    try std.testing.expectEqual(@as(u64, 0), host(client).graphics_store.ingressVersion());
    try std.testing.expectEqualDeep(version_before, client.model.version());
}

test "runtime stopping and stray history results" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();

    var payload: [128]u8 = undefined;
    const stopping = try encodeRuntimeStopping_module(&payload);
    try std.testing.expectEqual(
        @as(?u8, 0),
        try server_messages.handleServerMessage(harness.client, try decodeServer_module(stopping)),
    );

    const history = try encodeHistoryResults_module(&payload, .{
        .request_id = @enumFromInt(2),
        .entries = &.{},
    });
    try std.testing.expectEqual(
        @as(?u8, null),
        try server_messages.handleServerMessage(harness.client, try decodeServer_module(history)),
    );
    try std.testing.expectEqual(@as(u8, 0), harness.client.model.history_palette.len);

    const suggestion = try encodeCommandSuggestion_module(&payload, .{
        .request_id = @enumFromInt(3),
        .status = .ready,
        .text = "ls -la",
    });
    try std.testing.expectEqual(
        @as(?u8, null),
        try server_messages.handleServerMessage(harness.client, try decodeServer_module(suggestion)),
    );
    try std.testing.expectEqual(@as(u16, 0), harness.client.model.suggestion.text_len);
}

test "a pane clipboard write reaches the host terminal" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();

    const before = harness.sink.fullCount();
    var payload: [128]u8 = undefined;
    const clipboard = try encodePaneClipboard_module(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .bytes = "copied",
    });
    _ = try server_messages.handleServerMessage(harness.client, try decodeServer_module(clipboard));

    try std.testing.expectEqual(
        @as(u64, "\x1b]52;c;Y29waWVk\x07".len),
        harness.sink.fullCount() - before,
    );
}

test "an invalid pane clipboard writes no host bytes" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const before = harness.sink.fullCount();

    try std.testing.expectError(error.UnexpectedPane, pane_clipboards.apply(harness.client, .{
        .pane_id = .invalid,
        .bytes = "rejected",
    }));

    try std.testing.expectEqual(before, harness.sink.fullCount());
}
