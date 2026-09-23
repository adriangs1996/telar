//! Client integration tests for graphics and clipboard.

const core = @import("telar-core");
const TerminalClient = @import("../TerminalClient.zig");
const TestHarness = @import("TestHarness.zig");
const std = @import("std");
const presentation_lifecycle = @import("../presentation/presentation_lifecycle.zig");

test "a graphics revision break requests a graphics snapshot" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;

    var payload: [256]u8 = undefined;
    const begin = try core.encodeGraphicsSnapshot(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .revision = 8,
        .phase = .begin,
    });
    _ = try client.handleServerMessage(try core.decodeServer(begin));
    const image = try core.encodeGraphicsImage(&payload, .{
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
    _ = try client.handleServerMessage(try core.decodeServer(image));
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
    const pending_before = TerminalClient.of(client).presenter.pending_updates;

    var payload: [256]u8 = undefined;
    const encoded = try core.encodeGraphicsImage(&payload, .{
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
    _ = try client.handleServerMessage(try core.decodeServer(encoded));

    var committed = version_before;
    committed.pane_graphics += 1;
    try std.testing.expectEqualDeep(committed, client.model.version());
    try std.testing.expect(client.model.panes.find(TestHarness.bootstrap_pane).?.graphics_placeholder);
    try std.testing.expectEqual(pending_before, TerminalClient.of(client).presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_before + 1, TerminalClient.of(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(committed, TerminalClient.of(client).presenter.presentation_state.prepared.model);
}

test "presenter observes physical graphics without a semantic fallback" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    _ = try client.model.observeHostCapability(.{ .images = .supported });
    const version_before = client.model.version();
    const pending_before = TerminalClient.of(client).presenter.pending_updates;

    var payload: [256]u8 = undefined;
    const encoded = try core.encodeGraphicsImage(&payload, .{
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
    _ = try client.handleServerMessage(try core.decodeServer(encoded));

    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(@as(u64, 1), TerminalClient.of(client).graphics_store.ingressVersion());
    try std.testing.expectEqual(pending_before, TerminalClient.of(client).presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_before + 1, TerminalClient.of(client).presenter.pending_updates);
    try std.testing.expectEqual(@as(u64, 1), TerminalClient.of(client).presenter.presentation_state.observed.graphics_ingress);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(@as(u64, 1), TerminalClient.of(client).presenter.presentation_state.prepared.graphics_ingress);

    const pending_after = TerminalClient.of(client).presenter.pending_updates;
    const stale = try core.encodeGraphicsDeleteImage(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .revision = 4,
        .key = .{ .image_id = 1, .generation = 1 },
    });
    _ = try client.handleServerMessage(try core.decodeServer(stale));
    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(@as(u64, 1), TerminalClient.of(client).graphics_store.ingressVersion());
    try std.testing.expectEqual(pending_after, TerminalClient.of(client).presenter.pending_updates);
}

test "shared graphics mapping failure downgrades before resynchronizing" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before = client.model.version();

    var payload: [256]u8 = undefined;
    const encoded = try core.encodeGraphicsSharedImage(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
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
    _ = try client.handleServerMessage(try core.decodeServer(encoded));
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const downgrade = try harness.nextClientMessage(&buffer);
    const recovery = try harness.nextClientMessage(&buffer);
    try std.testing.expect(downgrade == .configure_graphics);
    try std.testing.expect(!downgrade.configure_graphics.shared);
    try std.testing.expect(recovery == .request_graphics_snapshot);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, recovery.request_graphics_snapshot.pane_id);
    try std.testing.expectEqual(@as(u64, 0), TerminalClient.of(client).graphics_store.ingressVersion());
    try std.testing.expectEqualDeep(version_before, client.model.version());
}

test "runtime stopping and stray history results" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();

    var payload: [128]u8 = undefined;
    const stopping = try core.encodeRuntimeStopping(&payload);
    try std.testing.expectEqual(
        @as(?u8, 0),
        try harness.client.handleServerMessage(try core.decodeServer(stopping)),
    );

    const history = try core.encodeHistoryResults(&payload, .{
        .request_id = @enumFromInt(2),
        .entries = &.{},
    });
    try std.testing.expectEqual(
        @as(?u8, null),
        try harness.client.handleServerMessage(try core.decodeServer(history)),
    );
    try std.testing.expectEqual(@as(u8, 0), harness.client.model.history_palette.len);

    const suggestion = try core.encodeCommandSuggestion(&payload, .{
        .request_id = @enumFromInt(3),
        .status = .ready,
        .text = "ls -la",
    });
    try std.testing.expectEqual(
        @as(?u8, null),
        try harness.client.handleServerMessage(try core.decodeServer(suggestion)),
    );
    try std.testing.expectEqual(@as(u16, 0), harness.client.model.suggestion.text_len);
}

test "a pane clipboard write reaches the host terminal" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();

    const before = harness.sink.fullCount();
    var payload: [128]u8 = undefined;
    const clipboard = try core.encodePaneClipboard(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .bytes = "copied",
    });
    _ = try harness.client.handleServerMessage(try core.decodeServer(clipboard));
    try harness.deliverHostEffects();

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

    try std.testing.expectError(error.UnexpectedPane, harness.client.handleServerMessage(
        .{
            .pane_clipboard = .{
                .pane_id = .invalid,
                .bytes = "rejected",
            },
        },
    ));

    try std.testing.expectEqual(before, harness.sink.fullCount());
}
