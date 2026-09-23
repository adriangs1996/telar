//! Client integration tests for host interaction.

const core = @import("telar-core");
const data = @import("model");
const client_module = @import("telar-client");
const TerminalClient = @import("../TerminalClient.zig");
const TestHarness = @import("TestHarness.zig");
const SizeType = @import("../../platform/Size.zig");
const host_resizes = @import("../controllers/host/host_resizes.zig");
const std = @import("std");
const presentation_lifecycle = @import("../presentation/presentation_lifecycle.zig");
const host_inputs = @import("../controllers/input/host_inputs.zig");
const capabilities_module = @import("../../graphics/capabilities.zig");
const client_events = @import("../entrypoints/events.zig");
const support = @import("support.zig");
const host_capabilities = @import("../controllers/host/host_capabilities.zig");

test "host resize commits before resources and presents by model version" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const pending_updates = TerminalClient.of(client).presenter.pending_updates;
    const measurement: SizeType = .{
        .cols = 100,
        .rows = 30,
        .width_px = 1000,
        .height_px = 600,
    };

    const commit = (try host_resizes.apply(client, measurement)).?.resize.?;

    const expected: core.TerminalSize = .{
        .cols = 100,
        .rows = 30,
        .cell_width_px = 10,
        .cell_height_px = 20,
    };
    try std.testing.expectEqualDeep(expected, commit.current);
    try std.testing.expectEqualDeep(expected, client.model.hostSize());
    try std.testing.expectEqual(data.Version{
        .host = 1,
        .host_capabilities = 1,
        .workspace = 1,
        .tabs = 1,
        .active_tab = 1,
        .panes = 1,
    }, client.model.version());
    try std.testing.expect(TerminalClient.of(client).presenter.screen.sizeMatches(100, 30));
    try std.testing.expectEqual(@as(u16, 100), TerminalClient.of(client).view.scratch.w);
    try std.testing.expectEqual(@as(u16, 30), TerminalClient.of(client).view.scratch.h);
    const active = client.model.tabs.active;
    try std.testing.expectEqual(@as(u16, 10), client.model.hostSize().cell_width_px);
    try std.testing.expectEqual(@as(u16, 20), client.model.hostSize().cell_height_px);
    try std.testing.expectEqual(pending_updates, TerminalClient.of(client).presenter.pending_updates);

    const expected_pane_size = data.tab_layout.contentSize(&client.model, active, 
        TestHarness.bootstrap_pane,
        TerminalClient.of(client).view.workbench(),
    ).?;
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .pane_resize);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, message.pane_resize.pane_id);
    try std.testing.expectEqualDeep(expected_pane_size, message.pane_resize.size);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates + 1, TerminalClient.of(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), TerminalClient.of(client).presenter.presentation_state.prepared.model);

    const version = client.model.version();
    const pending_after = TerminalClient.of(client).presenter.pending_updates;
    try std.testing.expect((try host_resizes.apply(client, measurement)) == null);
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expectEqual(pending_after, TerminalClient.of(client).presenter.pending_updates);
}

test "host resize retains committed geometry after outbox backpressure" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    while (client.runtime_transport.outbox.hasCapacity()) {
        try client.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }
    const pending_updates = TerminalClient.of(client).presenter.pending_updates;
    const measurement: SizeType = .{
        .cols = 90,
        .rows = 28,
        .width_px = 900,
        .height_px = 560,
    };

    try std.testing.expectError(error.ClientOutboxFull, host_resizes.apply(client, measurement));

    try std.testing.expectEqual(core.TerminalSize{
        .cols = 90,
        .rows = 28,
        .cell_width_px = 10,
        .cell_height_px = 20,
    }, client.model.hostSize());
    try std.testing.expectEqual(@as(u64, 1), client.model.version().host);
    try std.testing.expectEqual(@as(u64, 1), client.model.version().host_capabilities);
    try std.testing.expect(TerminalClient.of(client).presenter.screen.sizeMatches(90, 28));
    try std.testing.expectEqual(@as(u16, 90), TerminalClient.of(client).view.scratch.w);
    try std.testing.expectEqual(@as(u16, 28), TerminalClient.of(client).view.scratch.h);
    try std.testing.expectEqual(@as(usize, data.outbox_support.capacity), client.runtime_transport.outbox.len);
    try std.testing.expectEqual(pending_updates, TerminalClient.of(client).presenter.pending_updates);
}

test "host resize waits for canonical membership then resizes before attaching without duplicate opens" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const tab = client.model.tabs.active;
    const sibling: core.PaneId = @enumFromInt(20);
    try data.tab_snapshot_reconciliation.addDiscovered(&client.model, tab, 
        .{
            .pane_id = sibling,
            .location = client.model.tabs.location[tab],
            .area = client.geometry().area,
        },
    );
    try std.testing.expect(!client.model.tabs.snapshot_loaded[tab]);
    const initial_request_id = client.model.request_lifecycle.next_request_id;
    var buffer: [256]u8 = undefined;

    _ = try host_resizes.apply(
        client,
        .{
            .cols = 90,
            .rows = 28,
            .width_px = 900,
            .height_px = 560,
        },
    );
    try harness.settle();
    const before_snapshot = try harness.nextClientMessage(&buffer);
    try std.testing.expect(before_snapshot == .pane_resize);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, before_snapshot.pane_resize.pane_id);
    try std.testing.expectEqual(initial_request_id, client.model.request_lifecycle.next_request_id);
    try std.testing.expect(!client.model.request_lifecycle.tracker.hasPane(.attachment, sibling));

    _ = try client.model.reconcileTab(
        .{
            .location = client.model.tabs.location[tab],
            .panes = &.{
                TestHarness.bootstrap_pane,
                sibling,
            },
        },
        client.geometry().area,
    );
    _ = try host_resizes.apply(
        client,
        .{
            .cols = 100,
            .rows = 30,
            .width_px = 1000,
            .height_px = 600,
        },
    );
    try harness.settle();
    const resized = try harness.nextClientMessage(&buffer);
    try std.testing.expect(resized == .pane_resize);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, resized.pane_resize.pane_id);
    const opened = try harness.nextClientMessage(&buffer);
    try std.testing.expect(opened == .open_pane);
    try std.testing.expectEqual(sibling, opened.open_pane.target.pane);
    try std.testing.expectEqualDeep(data.tab_layout.contentSize(&client.model, tab, sibling, client.geometry().area).?, opened.open_pane.size);
    try std.testing.expect(client.model.request_lifecycle.tracker.hasPane(.attachment, sibling));
    const pending_request_id = client.model.request_lifecycle.next_request_id;

    _ = try host_resizes.apply(
        client,
        .{
            .cols = 110,
            .rows = 32,
            .width_px = 1100,
            .height_px = 640,
        },
    );
    try harness.settle();
    const repeated = try harness.nextClientMessage(&buffer);
    try std.testing.expect(repeated == .pane_resize);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, repeated.pane_resize.pane_id);
    try std.testing.expectEqual(pending_request_id, client.model.request_lifecycle.next_request_id);
}

test "host resize rolls back rejected attachment correlation after offering connected pane sizes" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const sibling: core.PaneId = @enumFromInt(20);
    _ = try client.model.reconcileTab(
        .{
            .location = TestHarness.bootstrap_location,
            .panes = &.{
                TestHarness.bootstrap_pane,
                sibling,
            },
        },
        client.geometry().area,
    );

    while (client.runtime_transport.outbox.len < data.outbox_support.capacity - 1) {
        try client.runtime_transport.outbox.push(
            .{
                .detach_pane = .{
                    .pane_id = TestHarness.bootstrap_pane,
                },
            },
        );
    }

    const initial_request_id = client.model.request_lifecycle.next_request_id;
    try std.testing.expectError(error.ClientOutboxFull, host_resizes.apply(
        client,
        .{
            .cols = 100,
            .rows = 30,
            .width_px = 1000,
            .height_px = 600,
        },
    ));

    try std.testing.expectEqual(initial_request_id + 1, client.model.request_lifecycle.next_request_id);
    try std.testing.expect(!client.model.request_lifecycle.tracker.hasPane(.attachment, sibling));
    try std.testing.expectEqual(@as(usize, data.outbox_support.capacity), client.runtime_transport.outbox.len);
    try std.testing.expectEqual(@as(u16, 100), client.model.hostSize().cols);
    try std.testing.expect(!client.model.panes.find(sibling).?.attached);
}

test "oversized host measurement changes neither model nor capabilities" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const host_size = client.model.hostSize();
    const capabilities = client.model.hostCapabilities();

    try std.testing.expectError(error.ScreenTooLarge, host_resizes.apply(client, .{
        .cols = std.math.maxInt(u16),
        .rows = std.math.maxInt(u16),
        .width_px = 1200,
        .height_px = 800,
    }));

    try std.testing.expectEqualDeep(host_size, client.model.hostSize());
    try std.testing.expectEqualDeep(capabilities, client.model.hostCapabilities());
    try std.testing.expectEqualDeep(data.Version{}, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "terminal pixel response keeps model host geometry authoritative" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const pending_updates = TerminalClient.of(client).presenter.pending_updates;

    try host_inputs.terminalResponse(client, .{ .cell_pixels = .{
        .width = 12,
        .height = 24,
    } });

    try std.testing.expectEqual(core.TerminalSize{
        .cols = 80,
        .rows = 24,
        .cell_width_px = 12,
        .cell_height_px = 24,
    }, client.model.hostSize());
    try std.testing.expectEqual(@as(u64, 1), client.model.version().host);
    try std.testing.expectEqual(@as(u64, 1), client.model.version().host_capabilities);
    try std.testing.expectEqual(@as(u16, 12), client.model.hostSize().cell_width_px);
    try std.testing.expectEqual(@as(u16, 24), client.model.hostSize().cell_height_px);
    try std.testing.expectEqual(pending_updates, TerminalClient.of(client).presenter.pending_updates);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates + 1, TerminalClient.of(client).presenter.pending_updates);
}

test "input timer expiries with nothing pending are a no-op" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();

    try std.testing.expect(!try host_inputs.handleInputTimeout(harness.client, {}));
    try std.testing.expect(!try host_inputs.handleBindingTimeout(harness.client, {}));
    try std.testing.expect(!TerminalClient.of(harness.client).host_input.input_timeout.pending);
    try std.testing.expect(!TerminalClient.of(harness.client).host_input.binding_timeout.pending);

    TerminalClient.of(harness.client).host_input.input_timeout.pending = true;
    try std.testing.expectError(
        error.InputTimerFailed,
        host_inputs.handleInputTimeout(harness.client, error.InputTimerFailed),
    );
    try std.testing.expect(!TerminalClient.of(harness.client).host_input.input_timeout.pending);

    TerminalClient.of(harness.client).host_input.binding_timeout.pending = true;
    try std.testing.expectError(
        error.BindingTimerFailed,
        host_inputs.handleBindingTimeout(harness.client, error.BindingTimerFailed),
    );
    try std.testing.expect(!TerminalClient.of(harness.client).host_input.binding_timeout.pending);
}

test "a Kitty capability response commits before fallback projection and presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

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
    try std.testing.expect(client.model.panes.find(TestHarness.bootstrap_pane).?.graphics_placeholder);
    const version = client.model.version();
    const pending_updates = TerminalClient.of(client).presenter.pending_updates;

    try host_inputs.terminalResponse(client, .{ .kitty_graphics = .{
        .image_id = capabilities_module.query_image_id,
        .supported = true,
    } });

    try std.testing.expectEqual(data.EnvironmentSupport.supported, client.model.hostCapabilities().images);
    try std.testing.expect(!client.model.panes.find(TestHarness.bootstrap_pane).?.graphics_placeholder);
    try std.testing.expectEqual(version.host_capabilities + 1, client.model.version().host_capabilities);
    try std.testing.expectEqual(version.pane_graphics + 1, client.model.version().pane_graphics);
    try std.testing.expectEqual(pending_updates, TerminalClient.of(client).presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates + 1, TerminalClient.of(client).presenter.pending_updates);
}

test "compression negotiation belongs to the TUI and does not revise the semantic model" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const version = client.model.version();

    try host_inputs.terminalResponse(client, .{ .kitty_graphics = .{
        .image_id = capabilities_module.zlib_query_image_id,
        .supported = true,
    } });
    try std.testing.expectEqual(data.EnvironmentSupport.supported, TerminalClient.of(client).host_negotiation.zlib_support);
    try std.testing.expect(TerminalClient.of(client).graphics_store.delivery.host_zlib);
    try std.testing.expectEqualDeep(version, client.model.version());

    try host_inputs.terminalResponse(client, .{ .kitty_graphics = .{
        .image_id = capabilities_module.zlib_query_image_id,
        .supported = false,
    } });
    try std.testing.expect(!TerminalClient.of(client).graphics_store.delivery.host_zlib);
    try std.testing.expectEqualDeep(version, client.model.version());
}

test "client event dispatch observes a completed capability expiry" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const pending_updates = TerminalClient.of(client).presenter.pending_updates;
    var heap = core.Heap.init(std.testing.allocator);
    TerminalClient.of(client).host_negotiation.deadline_ns = 0;

    const first = try client_events.handle(
        client,
        .{ .capability_timeout = {} },
        support.clientEventResourcesForTest(&heap),
    );

    try std.testing.expect(first == .keep_running);
    const capabilities = client.model.hostCapabilities();
    try std.testing.expectEqual(data.EnvironmentSupport.unsupported, capabilities.images);
    try std.testing.expectEqual(data.EnvironmentSupport.unsupported, TerminalClient.of(client).host_negotiation.zlib_support);
    try std.testing.expectEqual(data.EnvironmentSupport.unsupported, capabilities.pointer_pixels);
    try std.testing.expectEqual(data.Version{
        .host_capabilities = 1,
    }, client.model.version());
    try std.testing.expectEqual(pending_updates + 1, TerminalClient.of(client).presenter.pending_updates);
    try harness.settleModelPresentation();

    const version = client.model.version();
    const pending_after = TerminalClient.of(client).presenter.pending_updates;
    const repeated = try client_events.handle(
        client,
        .{ .capability_timeout = {} },
        support.clientEventResourcesForTest(&heap),
    );

    try std.testing.expect(repeated == .keep_running);
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(pending_after, TerminalClient.of(client).presenter.pending_updates);
}

test "TUI inbox drains a finite FIFO batch and observes presentation once" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    var heap = core.Heap.init(std.testing.allocator);
    const terminal = TerminalClient.of(client);
    const pending = terminal.presenter.pending_updates;
    _ = try client.model.setDiagnostic("inbox batch", .{});
    for (0..40) |_| {
        try terminal.inbox.post(.{ .notified = {} });
    }

    try std.testing.expect(try client_events.update(client, support.clientEventResourcesForTest(&heap)) == .keep_running);
    const stats = terminal.inbox.snapshot();
    try std.testing.expect(stats.consumed >= 1 and stats.consumed <= 32);
    try std.testing.expect(stats.depth >= 8);
    try std.testing.expectEqual(pending + 1, terminal.presenter.pending_updates);
    try std.testing.expectEqual(@as(u64, 1), stats.budget_yields);
}

test "client event dispatch skips observation after terminal input" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    var heap = core.Heap.init(std.testing.allocator);
    const observed = TerminalClient.of(client).presenter.presentation_state.observed.model;
    const pending_updates = TerminalClient.of(client).presenter.pending_updates;
    _ = try client.model.setDiagnostic("client is stopping", .{});

    const outcome = try client_events.handle(
        client,
        .{ .input = 0 },
        support.clientEventResourcesForTest(&heap),
    );

    try std.testing.expect(outcome == .exit);
    try std.testing.expectEqual(@as(u8, 0), outcome.exit);
    try std.testing.expectEqualDeep(observed, TerminalClient.of(client).presenter.presentation_state.observed.model);
    try std.testing.expectEqual(pending_updates, TerminalClient.of(client).presenter.pending_updates);
    try std.testing.expect(!std.meta.eql(client.model.version(), observed));
}

test "failed capability deadline changes no host state" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const capabilities = client.model.hostCapabilities();
    const version = client.model.version();

    try std.testing.expectError(
        error.CapabilityDeadlineFailed,
        host_capabilities.handleExpiry(client, error.CapabilityDeadlineFailed),
    );

    try std.testing.expectEqualDeep(capabilities, client.model.hostCapabilities());
    try std.testing.expectEqualDeep(version, client.model.version());
}

test "capability effect failure retains the committed fallback" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    TerminalClient.of(client).sidebar_rendering = .kitty_hybrid;
    const pending_updates = TerminalClient.of(client).presenter.pending_updates;
    TerminalClient.of(client).host_negotiation.deadline_ns = 0;

    try std.testing.expectError(
        error.KittyGraphicsUnsupported,
        host_capabilities.handleExpiry(client, {}),
    );

    try std.testing.expectEqual(data.EnvironmentSupport.unsupported, client.model.hostCapabilities().images);
    try std.testing.expectEqual(data.Version{
        .host_capabilities = 1,
    }, client.model.version());
    try std.testing.expectEqual(pending_updates, TerminalClient.of(client).presenter.pending_updates);
}

test "pane viewport intent commits before IPC and presenter-owned recomposition" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const pane = client.model.panes.find(TestHarness.bootstrap_pane).?;
    _ = try harness.addInactiveTab(@enumFromInt(2), @enumFromInt(20));
    const active = client.model.tabs.active;
    pane.scroll = .{
        .total_rows = @as(u32, pane.buffer.h) + 10,
        .offset = 10,
    };
    const version = client.model.version();
    const pending_updates = TerminalClient.of(client).presenter.pending_updates;
    const pane_view = data.tab_layout.view(&client.model, active, pane.id, TerminalClient.of(client).view.workbench()).?;
    try host_inputs.mouse(client, .{
        .x = pane_view.content.x,
        .y = pane_view.content.y,
        .kind = .move,
    });

    try host_inputs.mouse(client, .{
        .x = pane_view.content.x,
        .y = pane_view.content.y,
        .kind = .scroll_up,
    });

    try std.testing.expectEqual(@as(u32, 7), pane.scroll.offset);
    try std.testing.expect(!TerminalClient.of(client).graphics_store.paneVisible(pane.id));
    try std.testing.expectEqual(pending_updates, TerminalClient.of(client).presenter.pending_updates);

    try host_inputs.key(client, try data.chord.parseKey("x"));

    try std.testing.expectEqual(@as(u32, 10), pane.scroll.offset);
    try std.testing.expect(TerminalClient.of(client).graphics_store.paneVisible(pane.id));
    try std.testing.expectEqual(version.viewport + 2, client.model.version().viewport);
    try support.expectNonViewportVersionEqual(version, client.model.version());
    try std.testing.expectEqual(pending_updates, TerminalClient.of(client).presenter.pending_updates);

    try harness.settle();
    var buffer: [256]u8 = undefined;
    const scrolled = try harness.nextClientMessage(&buffer);
    try std.testing.expect(scrolled == .set_pane_viewport);
    try std.testing.expectEqual(pane.id, scrolled.set_pane_viewport.pane_id);
    try std.testing.expectEqual(@as(u32, 7), scrolled.set_pane_viewport.offset);
    const restored = try harness.nextClientMessage(&buffer);
    try std.testing.expect(restored == .set_pane_viewport);
    try std.testing.expectEqual(pane.id, restored.set_pane_viewport.pane_id);
    try std.testing.expectEqual(@as(u32, 10), restored.set_pane_viewport.offset);
    const input = try harness.nextClientMessage(&buffer);
    try std.testing.expect(input == .pane_input);
    try std.testing.expectEqual(pane.id, input.pane_input.pane_id);
    try std.testing.expectEqualStrings("x", input.pane_input.bytes);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates + 1, TerminalClient.of(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), TerminalClient.of(client).presenter.presentation_state.prepared.model);
}

test "native scroll actions reuse bounded viewport delivery without forwarding input" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const pane = client.model.panes.find(TestHarness.bootstrap_pane).?;
    pane.scroll = .{ .total_rows = @as(u32, pane.buffer.h) + 10, .offset = 10 };
    const version = client.model.version();
    const pending_updates = TerminalClient.of(client).presenter.pending_updates;

    for (0..4) |_| {
        _ = try client.executeAction(try data.Action.parse("scroll-pane-up"), .effect);
    }

    try std.testing.expectEqual(@as(u32, 0), pane.scroll.offset);
    _ = try client.executeAction(
        .{
            .scroll_pane = .up,
        },
        .effect,
    );

    for (0..4) |_| {
        _ = try client.executeAction(try data.Action.parse("scroll-pane-down"), .effect);
    }

    _ = try client.executeAction(
        .{
            .scroll_pane = .down,
        },
        .effect,
    );
    try std.testing.expectEqual(@as(u32, 10), pane.scroll.offset);
    try std.testing.expectEqual(version.viewport + 8, client.model.version().viewport);
    try support.expectNonViewportVersionEqual(version, client.model.version());
    try std.testing.expectEqual(pending_updates, TerminalClient.of(client).presenter.pending_updates);

    try harness.settle();
    var buffer: [256]u8 = undefined;
    for ([_]u32{ 7, 4, 1, 0, 3, 6, 9, 10 }) |offset| {
        const message = try harness.nextClientMessage(&buffer);
        try std.testing.expect(message == .set_pane_viewport);
        try std.testing.expectEqual(pane.id, message.set_pane_viewport.pane_id);
        try std.testing.expectEqual(offset, message.set_pane_viewport.offset);
    }
}

test "a full outbox preserves the committed pane viewport and rejects input" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const pane = client.model.panes.find(TestHarness.bootstrap_pane).?;
    pane.scroll = .{
        .total_rows = @as(u32, pane.buffer.h) + 10,
        .offset = 0,
    };
    try TerminalClient.of(client).graphics_store.setPaneVisible(pane.id, false);
    while (client.runtime_transport.outbox.hasCapacity()) {
        try client.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = pane.id } });
    }
    const version = client.model.version();
    const pending_updates = TerminalClient.of(client).presenter.pending_updates;

    try std.testing.expectError(
        error.ClientOutboxFull,
        host_inputs.key(client, try data.chord.parseKey("x")),
    );

    try std.testing.expectEqual(@as(u32, 10), pane.scroll.offset);
    try std.testing.expect(TerminalClient.of(client).graphics_store.paneVisible(pane.id));
    try std.testing.expectEqual(version.viewport + 1, client.model.version().viewport);
    try support.expectNonViewportVersionEqual(version, client.model.version());
    try std.testing.expectEqual(pending_updates, TerminalClient.of(client).presenter.pending_updates);
}

test "copy mode round trip: enter, select, copy, leave" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const pane = client.model.panes.find(TestHarness.bootstrap_pane).?;
    pane.scroll = .{ .total_rows = 30, .offset = 6 };
    pane.cursor = .{ .visible = true, .x = 0, .y = 0 };
    const version_before = client.model.version();
    const pending_updates_before = TerminalClient.of(client).presenter.pending_updates;

    try std.testing.expectEqual(
        data.KeybindControl.continue_routing,
        try client.executeAction(.enter_copy_mode, .effect),
    );
    try std.testing.expect(client.model.copyModeActive());
    try std.testing.expect(!data.key_routing.captures(client.keyRoutingAuthority()));
    try std.testing.expect(!client.openNamePrompt(.rename_active_tab));
    try std.testing.expect(!client.model.name_prompt.active());
    try support.expectNonCopyVersionEqual(version_before, client.model.version());
    try std.testing.expectEqual(version_before.copy + 1, client.model.version().copy);
    try std.testing.expectEqual(pending_updates_before, TerminalClient.of(client).presenter.pending_updates);
    try std.testing.expect(TerminalClient.of(client).presenter.compositor.copy == null);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates_before + 1, TerminalClient.of(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expect(TerminalClient.of(client).presenter.compositor.copy != null);
    try std.testing.expectEqualDeep(
        client.model.copyModeProjection().?.view,
        TerminalClient.of(client).presenter.compositor.copy.?.view,
    );
    const painted_cursor_y = TerminalClient.of(client).presenter.compositor.copy.?.view.cursor.y;

    const pane_view = data.tab_layout.view(&client.model, client.model.tabs.active, 
        pane.id,
        TerminalClient.of(client).view.workbench(),
    ).?;
    const mouse_version = client.model.version();
    try host_inputs.mouse(client, .{
        .x = pane_view.content.x,
        .y = pane_view.content.y,
        .kind = .press,
    });
    try std.testing.expectEqualDeep(mouse_version, client.model.version());
    try host_inputs.mouse(client, .{
        .x = pane_view.content.x,
        .y = pane_view.content.y,
        .kind = .scroll_up,
    });
    try std.testing.expectEqual(mouse_version.copy + 1, client.model.version().copy);
    try std.testing.expectEqual(mouse_version.viewport + 1, client.model.version().viewport);
    try support.expectNonCopyOrViewportVersionEqual(mouse_version, client.model.version());
    try std.testing.expectEqual(painted_cursor_y - 3, client.model.copyModeProjection().?.view.cursor.y);
    try std.testing.expectEqual(painted_cursor_y, TerminalClient.of(client).presenter.compositor.copy.?.view.cursor.y);

    // While in copy mode, keys route to the selection, not the pane.
    try host_inputs.key(client, try data.chord.parseKey("v"));
    try host_inputs.key(client, try data.chord.parseKey("l"));
    try std.testing.expectEqual(@as(u16, 0), TerminalClient.of(client).presenter.compositor.copy.?.view.cursor.x);
    try std.testing.expectEqual(pending_updates_before, TerminalClient.of(client).presenter.pending_updates);
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(@as(u16, 1), TerminalClient.of(client).presenter.compositor.copy.?.view.cursor.x);
    try std.testing.expect(TerminalClient.of(client).presenter.compositor.copy.?.view.anchor != null);

    const version_before_copy = client.model.version();
    try host_inputs.key(client, try data.chord.parseKey("enter"));
    try std.testing.expect(!client.model.copyModeActive());
    try support.expectNonCopyOrViewportVersionEqual(version_before_copy, client.model.version());
    try std.testing.expectEqual(version_before_copy.copy + 1, client.model.version().copy);
    try std.testing.expectEqual(version_before_copy.viewport + 1, client.model.version().viewport);
    try std.testing.expect(TerminalClient.of(client).presenter.compositor.copy != null);
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    try std.testing.expect(TerminalClient.of(client).presenter.compositor.copy == null);
    try std.testing.expectEqualDeep(client.model.version(), TerminalClient.of(client).presenter.presentation_state.prepared.model);
    try harness.settle();

    var buffer: [256]u8 = undefined;
    var copied = false;
    while (!copied) {
        switch (try harness.nextClientMessage(&buffer)) {
            .copy_selection => |selection| {
                try std.testing.expectEqual(TestHarness.bootstrap_pane, selection.pane_id);
                try std.testing.expectEqual(@as(u16, 1), selection.end_x);
                copied = true;
            },
            .set_pane_viewport, .pane_input => {},
            else => return error.UnexpectedClientMessage,
        }
    }
}

test "copy-mode o opens a file URI in an editor tab without leaving the mode" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.options.editor = "nvim";
    const pane = client.model.panes.find(TestHarness.bootstrap_pane).?;
    pane.buffer.fill(pane.buffer.area(), .{ .glyph = " ", .style = .{} });
    _ = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "file:///tmp/a%20b.txt", .style = .{} });
    pane.cursor = .{ .visible = true, .x = 12, .y = 0 };

    _ = try client.executeAction(.enter_copy_mode, .effect);
    const version = client.model.version();
    try host_inputs.key(client, try data.chord.parseKey("o"));

    try std.testing.expect(client.model.copyModeActive());
    try std.testing.expectEqualDeep(version, client.model.version());
    try harness.settle();

    var buffer: [512]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .create_tab);
    var arguments = message.create_tab.launch.arguments();
    try std.testing.expectEqualStrings("nvim", (try arguments.next()).?);
    try std.testing.expectEqualStrings("/tmp/a b.txt", (try arguments.next()).?);
    try std.testing.expect(try arguments.next() == null);
}

test "a left click opens a file URI and owns the complete mouse gesture" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.options.editor = "nvim";
    const pane = client.model.panes.find(TestHarness.bootstrap_pane).?;
    pane.buffer.fill(pane.buffer.area(), .{ .glyph = " ", .style = .{} });
    _ = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "file:///tmp/click.txt", .style = .{} });
    const pane_view = data.tab_layout.view(&client.model, client.model.tabs.active, 
        pane.id,
        TerminalClient.of(client).view.workbench(),
    ).?;

    try host_inputs.mouse(client, .{
        .x = pane_view.content.x + 10,
        .y = pane_view.content.y,
        .kind = .press,
        .button = 0,
    });
    try std.testing.expect(client.model.link_pointer.owned);
    try host_inputs.mouse(client, .{
        .x = pane_view.content.x + 10,
        .y = pane_view.content.y,
        .kind = .release,
        .button = 0,
    });
    try std.testing.expect(!client.model.link_pointer.owned);
    try harness.settle();

    var buffer: [512]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .create_tab);
    var arguments = message.create_tab.launch.arguments();
    try std.testing.expectEqualStrings("nvim", (try arguments.next()).?);
    try std.testing.expectEqualStrings("/tmp/click.txt", (try arguments.next()).?);
    try std.testing.expect(try arguments.next() == null);
}

test "native action preflight retires copy mode before concrete delivery" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    _ = try client.executeAction(.enter_copy_mode, .effect);
    const version = client.model.version();

    try std.testing.expect(client.model.copyModeActive());
    try std.testing.expect(client.model.sidebarVisible());
    try std.testing.expectEqual(
        data.KeybindControl.continue_routing,
        try client.executeAction(.toggle_sidebar, .effect),
    );

    var expected = version;
    expected.copy += 1;
    expected.chrome += 1;
    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expect(!client.model.sidebarVisible());
    try std.testing.expectEqualDeep(expected, client.model.version());
}

test "copy-mode pointer consumes outside wheels and exits a missing target" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    _ = try client.executeAction(.enter_copy_mode, .effect);
    const active_version = client.model.version();

    try host_inputs.mouse(client, .{
        .x = std.math.maxInt(u16),
        .y = std.math.maxInt(u16),
        .kind = .scroll_up,
    });

    try std.testing.expect(client.model.copyModeActive());
    try std.testing.expectEqualDeep(active_version, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);

    try std.testing.expect(data.tab_layout.removePane(&client.model, TestHarness.bootstrap_pane));
    try host_inputs.mouse(client, .{ .x = 0, .y = 0, .kind = .move });

    try std.testing.expect(!client.model.copyModeActive());
    try support.expectNonCopyVersionEqual(active_version, client.model.version());
    try std.testing.expectEqual(active_version.copy + 1, client.model.version().copy);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "a full outbox keeps copy mode and its selection active" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    while (client.runtime_transport.outbox.hasCapacity()) {
        try client.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }

    _ = try client.executeAction(.enter_copy_mode, .effect);
    try host_inputs.key(client, try data.chord.parseKey("v"));
    const version = client.model.version();

    try std.testing.expectError(
        error.ClientOutboxFull,
        host_inputs.key(client, try data.chord.parseKey("enter")),
    );

    try std.testing.expect(client.model.copyModeActive());
    try std.testing.expect(client.model.copyModeProjection().?.view.anchor != null);
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(data.outbox_support.capacity, @as(usize, client.runtime_transport.outbox.len));
}
