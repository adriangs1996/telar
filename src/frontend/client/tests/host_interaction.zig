//! Client integration tests for host interaction.

const TerminalClient = @import("../TerminalClient.zig");
const host = TerminalClient.of;
const TestHarness = @import("TestHarness.zig");
const SizeType = @import("../../platform/Size.zig");
const host_resizes = @import("../controllers/host/host_resizes.zig");
const TerminalSizeType = @import("telar-core").TerminalSize;
const std = @import("std");
const VersionType = @import("telar-client").Version;
const presentation_lifecycle = @import("../presentation/presentation_lifecycle.zig");
const capacity_module = @import("telar-client").capacity;
const InputHandler = @import("../resources/InputHandler.zig");
const host_inputs = @import("../controllers/input/host_inputs.zig");
const encodeGraphicsImage_module = @import("telar-core").encodeGraphicsImage;
const server_messages = @import("telar-client").server_messages;
const decodeServer_module = @import("telar-core").decodeServer;
const capabilities_module = @import("../../graphics/capabilities.zig");
const SupportType = @import("telar-client").Support;
const HeapType = @import("telar-core").Heap;
const client_events = @import("../entrypoints/events.zig");
const support = @import("support.zig");
const host_capabilities = @import("../controllers/host/host_capabilities.zig");
const parseKey_module = @import("telar-client").parseKey;
const client_actions = @import("telar-client").controllers.actions;
const ActionType = @import("telar-client").Action;
const ControlType = @import("telar-client").Control;
const name_prompts = @import("telar-client").controllers.name_prompts;

test "host resize commits before resources and presents by model version" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const pending_updates = host(client).presenter.pending_updates;
    const measurement: SizeType = .{
        .cols = 100,
        .rows = 30,
        .width_px = 1000,
        .height_px = 600,
    };

    const commit = (try host_resizes.apply(client, measurement)).?.resize.?;

    const expected: TerminalSizeType = .{
        .cols = 100,
        .rows = 30,
        .cell_width_px = 10,
        .cell_height_px = 20,
    };
    try std.testing.expectEqualDeep(expected, commit.current);
    try std.testing.expectEqualDeep(expected, client.model.hostSize());
    try std.testing.expectEqual(VersionType{
        .host = 1,
        .host_capabilities = 1,
        .workspace = 1,
        .tabs = 1,
        .active_tab = 1,
        .panes = 1,
    }, client.model.version());
    try std.testing.expect(host(client).presenter.screen.sizeMatches(100, 30));
    try std.testing.expectEqual(@as(u16, 100), host(client).view.scratch.w);
    try std.testing.expectEqual(@as(u16, 30), host(client).view.scratch.h);
    const active = client.model.workspace.active().?;
    try std.testing.expectEqual(@as(u16, 10), active.model.cell_width_px);
    try std.testing.expectEqual(@as(u16, 20), active.model.cell_height_px);
    try std.testing.expectEqual(pending_updates, host(client).presenter.pending_updates);

    const expected_pane_size = active.model.contentSize(
        TestHarness.bootstrap_pane,
        host(client).view.workbench(),
    ).?;
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .pane_resize);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, message.pane_resize.pane_id);
    try std.testing.expectEqualDeep(expected_pane_size, message.pane_resize.size);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates + 1, host(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), host(client).presenter.presentation_state.prepared.model);

    const version = client.model.version();
    const pending_after = host(client).presenter.pending_updates;
    try std.testing.expect((try host_resizes.apply(client, measurement)) == null);
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expectEqual(pending_after, host(client).presenter.pending_updates);
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
    const pending_updates = host(client).presenter.pending_updates;
    const measurement: SizeType = .{
        .cols = 90,
        .rows = 28,
        .width_px = 900,
        .height_px = 560,
    };

    try std.testing.expectError(error.ClientOutboxFull, host_resizes.apply(client, measurement));

    try std.testing.expectEqual(TerminalSizeType{
        .cols = 90,
        .rows = 28,
        .cell_width_px = 10,
        .cell_height_px = 20,
    }, client.model.hostSize());
    try std.testing.expectEqual(@as(u64, 1), client.model.version().host);
    try std.testing.expectEqual(@as(u64, 1), client.model.version().host_capabilities);
    try std.testing.expect(host(client).presenter.screen.sizeMatches(90, 28));
    try std.testing.expectEqual(@as(u16, 90), host(client).view.scratch.w);
    try std.testing.expectEqual(@as(u16, 28), host(client).view.scratch.h);
    try std.testing.expectEqual(@as(usize, capacity_module), client.runtime_transport.outbox.len);
    try std.testing.expectEqual(pending_updates, host(client).presenter.pending_updates);
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
    try std.testing.expectEqualDeep(VersionType{}, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "terminal pixel response keeps model host geometry authoritative" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const pending_updates = host(client).presenter.pending_updates;
    var handler: InputHandler = .{ .client = client };

    try handler.terminalResponse(.{ .cell_pixels = .{
        .width = 12,
        .height = 24,
    } });

    try std.testing.expectEqual(TerminalSizeType{
        .cols = 80,
        .rows = 24,
        .cell_width_px = 12,
        .cell_height_px = 24,
    }, client.model.hostSize());
    try std.testing.expectEqual(@as(u64, 1), client.model.version().host);
    try std.testing.expectEqual(@as(u64, 1), client.model.version().host_capabilities);
    const active = client.model.workspace.active().?;
    try std.testing.expectEqual(@as(u16, 12), active.model.cell_width_px);
    try std.testing.expectEqual(@as(u16, 24), active.model.cell_height_px);
    try std.testing.expectEqual(pending_updates, host(client).presenter.pending_updates);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates + 1, host(client).presenter.pending_updates);
}

test "input timer expiries with nothing pending are a no-op" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();

    try std.testing.expect(!try host_inputs.handleInputTimeout(harness.client, {}));
    try std.testing.expect(!try host_inputs.handleBindingTimeout(harness.client, {}));
    try std.testing.expect(!host(harness.client).host_input.input_timeout.pending);
    try std.testing.expect(!host(harness.client).host_input.binding_timeout.pending);

    host(harness.client).host_input.input_timeout.pending = true;
    try std.testing.expectError(
        error.InputTimerFailed,
        host_inputs.handleInputTimeout(harness.client, error.InputTimerFailed),
    );
    try std.testing.expect(!host(harness.client).host_input.input_timeout.pending);

    host(harness.client).host_input.binding_timeout.pending = true;
    try std.testing.expectError(
        error.BindingTimerFailed,
        host_inputs.handleBindingTimeout(harness.client, error.BindingTimerFailed),
    );
    try std.testing.expect(!host(harness.client).host_input.binding_timeout.pending);
}

test "a Kitty capability response commits before fallback projection and presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

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
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.graphics_placeholder);
    const version = client.model.version();
    const pending_updates = host(client).presenter.pending_updates;
    var handler: InputHandler = .{ .client = client };

    try handler.terminalResponse(.{ .kitty_graphics = .{
        .image_id = capabilities_module.query_image_id,
        .supported = true,
    } });

    try std.testing.expectEqual(SupportType.supported, client.model.hostCapabilities().images);
    try std.testing.expect(!client.model.workspace.findPane(TestHarness.bootstrap_pane).?.graphics_placeholder);
    try std.testing.expectEqual(version.host_capabilities + 1, client.model.version().host_capabilities);
    try std.testing.expectEqual(version.pane_graphics + 1, client.model.version().pane_graphics);
    try std.testing.expectEqual(pending_updates, host(client).presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates + 1, host(client).presenter.pending_updates);
}

test "compression negotiation belongs to the TUI and does not revise the semantic model" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const version = client.model.version();
    var handler: InputHandler = .{ .client = client };

    try handler.terminalResponse(.{ .kitty_graphics = .{
        .image_id = capabilities_module.zlib_query_image_id,
        .supported = true,
    } });
    try std.testing.expectEqual(SupportType.supported, host(client).host_negotiation.zlib_support);
    try std.testing.expect(host(client).graphics_store.delivery.host_zlib);
    try std.testing.expectEqualDeep(version, client.model.version());

    try handler.terminalResponse(.{ .kitty_graphics = .{
        .image_id = capabilities_module.zlib_query_image_id,
        .supported = false,
    } });
    try std.testing.expect(!host(client).graphics_store.delivery.host_zlib);
    try std.testing.expectEqualDeep(version, client.model.version());
}

test "client event dispatch observes a completed capability expiry" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const pending_updates = host(client).presenter.pending_updates;
    var heap = HeapType.init(std.testing.allocator);
    host(client).host_negotiation.deadline_ns = 0;

    const first = try client_events.handle(
        client,
        .{ .capability_timeout = {} },
        support.clientEventResourcesForTest(&heap),
    );

    try std.testing.expect(first == .keep_running);
    const capabilities = client.model.hostCapabilities();
    try std.testing.expectEqual(SupportType.unsupported, capabilities.images);
    try std.testing.expectEqual(SupportType.unsupported, host(client).host_negotiation.zlib_support);
    try std.testing.expectEqual(SupportType.unsupported, capabilities.pointer_pixels);
    try std.testing.expectEqual(VersionType{
        .host_capabilities = 1,
    }, client.model.version());
    try std.testing.expectEqual(pending_updates + 1, host(client).presenter.pending_updates);
    try harness.settleModelPresentation();

    const version = client.model.version();
    const pending_after = host(client).presenter.pending_updates;
    const repeated = try client_events.handle(
        client,
        .{ .capability_timeout = {} },
        support.clientEventResourcesForTest(&heap),
    );

    try std.testing.expect(repeated == .keep_running);
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(pending_after, host(client).presenter.pending_updates);
}

test "client event dispatch skips observation after terminal input" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    var heap = HeapType.init(std.testing.allocator);
    const observed = host(client).presenter.presentation_state.observed.model;
    const pending_updates = host(client).presenter.pending_updates;
    _ = try client.model.setDiagnostic("client is stopping", .{});

    const outcome = try client_events.handle(
        client,
        .{ .input = 0 },
        support.clientEventResourcesForTest(&heap),
    );

    try std.testing.expect(outcome == .exit);
    try std.testing.expectEqual(@as(u8, 0), outcome.exit);
    try std.testing.expectEqualDeep(observed, host(client).presenter.presentation_state.observed.model);
    try std.testing.expectEqual(pending_updates, host(client).presenter.pending_updates);
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
    host(client).sidebar_rendering = .kitty_hybrid;
    const pending_updates = host(client).presenter.pending_updates;
    host(client).host_negotiation.deadline_ns = 0;

    try std.testing.expectError(
        error.KittyGraphicsUnsupported,
        host_capabilities.handleExpiry(client, {}),
    );

    try std.testing.expectEqual(SupportType.unsupported, client.model.hostCapabilities().images);
    try std.testing.expectEqual(VersionType{
        .host_capabilities = 1,
    }, client.model.version());
    try std.testing.expectEqual(pending_updates, host(client).presenter.pending_updates);
}

test "pane viewport intent commits before IPC and presenter-owned recomposition" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const pane = client.model.workspace.findPane(TestHarness.bootstrap_pane).?;
    _ = try harness.addInactiveTab(@enumFromInt(2), @enumFromInt(20));
    const active = client.model.workspace.active().?;
    pane.scroll = .{
        .total_rows = @as(u32, pane.buffer.h) + 10,
        .offset = 10,
    };
    const version = client.model.version();
    const pending_updates = host(client).presenter.pending_updates;
    const pane_view = active.model.viewForPane(pane.id, host(client).view.workbench()).?;
    var handler: InputHandler = .{ .client = client };
    try handler.mouse(.{
        .x = pane_view.content.x,
        .y = pane_view.content.y,
        .kind = .move,
    });

    try handler.mouse(.{
        .x = pane_view.content.x,
        .y = pane_view.content.y,
        .kind = .scroll_up,
    });

    try std.testing.expectEqual(@as(u32, 7), pane.scroll.offset);
    try std.testing.expect(!host(client).graphics_store.paneVisible(pane.id));
    try std.testing.expectEqual(pending_updates, host(client).presenter.pending_updates);

    try handler.key(try parseKey_module("x"));

    try std.testing.expectEqual(@as(u32, 10), pane.scroll.offset);
    try std.testing.expect(host(client).graphics_store.paneVisible(pane.id));
    try std.testing.expectEqual(version.viewport + 2, client.model.version().viewport);
    try support.expectNonViewportVersionEqual(version, client.model.version());
    try std.testing.expectEqual(pending_updates, host(client).presenter.pending_updates);

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
    try std.testing.expectEqual(pending_updates + 1, host(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), host(client).presenter.presentation_state.prepared.model);
}

test "native scroll actions reuse bounded viewport delivery without forwarding input" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const pane = client.model.workspace.findPane(TestHarness.bootstrap_pane).?;
    pane.scroll = .{ .total_rows = @as(u32, pane.buffer.h) + 10, .offset = 10 };
    const version = client.model.version();
    const pending_updates = host(client).presenter.pending_updates;

    for (0..4) |_| {
        _ = try client_actions.apply(client, try ActionType.parse("scroll-pane-up"));
    }

    try std.testing.expectEqual(@as(u32, 0), pane.scroll.offset);
    _ = try client_actions.apply(client, .{ .scroll_pane = .up });

    for (0..4) |_| {
        _ = try client_actions.apply(client, try ActionType.parse("scroll-pane-down"));
    }

    _ = try client_actions.apply(client, .{ .scroll_pane = .down });
    try std.testing.expectEqual(@as(u32, 10), pane.scroll.offset);
    try std.testing.expectEqual(version.viewport + 8, client.model.version().viewport);
    try support.expectNonViewportVersionEqual(version, client.model.version());
    try std.testing.expectEqual(pending_updates, host(client).presenter.pending_updates);

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
    const pane = client.model.workspace.findPane(TestHarness.bootstrap_pane).?;
    pane.scroll = .{
        .total_rows = @as(u32, pane.buffer.h) + 10,
        .offset = 0,
    };
    try host(client).graphics_store.setPaneVisible(pane.id, false);
    while (client.runtime_transport.outbox.hasCapacity()) {
        try client.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = pane.id } });
    }
    const version = client.model.version();
    const pending_updates = host(client).presenter.pending_updates;
    var handler: InputHandler = .{ .client = client };

    try std.testing.expectError(
        error.ClientOutboxFull,
        handler.key(try parseKey_module("x")),
    );

    try std.testing.expectEqual(@as(u32, 10), pane.scroll.offset);
    try std.testing.expect(host(client).graphics_store.paneVisible(pane.id));
    try std.testing.expectEqual(version.viewport + 1, client.model.version().viewport);
    try support.expectNonViewportVersionEqual(version, client.model.version());
    try std.testing.expectEqual(pending_updates, host(client).presenter.pending_updates);
}

test "copy mode round trip: enter, select, copy, leave" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const pane = client.model.workspace.findPane(TestHarness.bootstrap_pane).?;
    pane.scroll = .{ .total_rows = 30, .offset = 6 };
    pane.cursor = .{ .visible = true, .x = 0, .y = 0 };
    const version_before = client.model.version();
    const pending_updates_before = host(client).presenter.pending_updates;

    var handler: InputHandler = .{ .client = client };
    try std.testing.expectEqual(
        ControlType.continue_routing,
        try client_actions.apply(handler.client, .enter_copy_mode),
    );
    try std.testing.expect(client.model.copyModeActive());
    try std.testing.expect(!handler.capturesKeys());
    try std.testing.expect(!name_prompts.beginActiveTabRename(client));
    try std.testing.expect(!client.model.name_prompt.active());
    try support.expectNonCopyVersionEqual(version_before, client.model.version());
    try std.testing.expectEqual(version_before.copy + 1, client.model.version().copy);
    try std.testing.expectEqual(pending_updates_before, host(client).presenter.pending_updates);
    try std.testing.expect(host(client).presenter.compositor.copy == null);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates_before + 1, host(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expect(host(client).presenter.compositor.copy != null);
    try std.testing.expectEqualDeep(
        client.model.copyModeProjection().?.view,
        host(client).presenter.compositor.copy.?.view,
    );
    const painted_cursor_y = host(client).presenter.compositor.copy.?.view.cursor.y;

    const pane_view = client.model.workspace.active().?.model.viewForPane(
        pane.id,
        host(client).view.workbench(),
    ).?;
    const mouse_version = client.model.version();
    try handler.mouse(.{
        .x = pane_view.content.x,
        .y = pane_view.content.y,
        .kind = .press,
    });
    try std.testing.expectEqualDeep(mouse_version, client.model.version());
    try handler.mouse(.{
        .x = pane_view.content.x,
        .y = pane_view.content.y,
        .kind = .scroll_up,
    });
    try std.testing.expectEqual(mouse_version.copy + 1, client.model.version().copy);
    try std.testing.expectEqual(mouse_version.viewport + 1, client.model.version().viewport);
    try support.expectNonCopyOrViewportVersionEqual(mouse_version, client.model.version());
    try std.testing.expectEqual(painted_cursor_y - 3, client.model.copyModeProjection().?.view.cursor.y);
    try std.testing.expectEqual(painted_cursor_y, host(client).presenter.compositor.copy.?.view.cursor.y);

    // While in copy mode, keys route to the selection, not the pane.
    try handler.key(try parseKey_module("v"));
    try handler.key(try parseKey_module("l"));
    try std.testing.expectEqual(@as(u16, 0), host(client).presenter.compositor.copy.?.view.cursor.x);
    try std.testing.expectEqual(pending_updates_before, host(client).presenter.pending_updates);
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(@as(u16, 1), host(client).presenter.compositor.copy.?.view.cursor.x);
    try std.testing.expect(host(client).presenter.compositor.copy.?.view.anchor != null);

    const version_before_copy = client.model.version();
    try handler.key(try parseKey_module("enter"));
    try std.testing.expect(!client.model.copyModeActive());
    try support.expectNonCopyOrViewportVersionEqual(version_before_copy, client.model.version());
    try std.testing.expectEqual(version_before_copy.copy + 1, client.model.version().copy);
    try std.testing.expectEqual(version_before_copy.viewport + 1, client.model.version().viewport);
    try std.testing.expect(host(client).presenter.compositor.copy != null);
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    try std.testing.expect(host(client).presenter.compositor.copy == null);
    try std.testing.expectEqualDeep(client.model.version(), host(client).presenter.presentation_state.prepared.model);
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
    const pane = client.model.workspace.findPane(TestHarness.bootstrap_pane).?;
    pane.buffer.fill(pane.buffer.area(), .{ .glyph = " ", .style = .{} });
    _ = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "file:///tmp/a%20b.txt", .style = .{} });
    pane.cursor = .{ .visible = true, .x = 12, .y = 0 };

    var handler: InputHandler = .{ .client = client };
    _ = try client_actions.apply(client, .enter_copy_mode);
    const version = client.model.version();
    try handler.key(try parseKey_module("o"));

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
    const pane = client.model.workspace.findPane(TestHarness.bootstrap_pane).?;
    pane.buffer.fill(pane.buffer.area(), .{ .glyph = " ", .style = .{} });
    _ = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "file:///tmp/click.txt", .style = .{} });
    const pane_view = client.model.workspace.active().?.model.viewForPane(
        pane.id,
        host(client).view.workbench(),
    ).?;

    var handler: InputHandler = .{ .client = client };
    try handler.mouse(.{
        .x = pane_view.content.x + 10,
        .y = pane_view.content.y,
        .kind = .press,
        .button = 0,
    });
    try std.testing.expect(client.link_pointer.owned);
    try handler.mouse(.{
        .x = pane_view.content.x + 10,
        .y = pane_view.content.y,
        .kind = .release,
        .button = 0,
    });
    try std.testing.expect(!client.link_pointer.owned);
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
    _ = try client_actions.apply(client, .enter_copy_mode);
    const version = client.model.version();

    try std.testing.expect(client.model.copyModeActive());
    try std.testing.expect(client.model.sidebarVisible());
    try std.testing.expectEqual(
        ControlType.continue_routing,
        try client_actions.apply(client, .toggle_sidebar),
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
    const model = &client.model.workspace.active().?.model;
    var handler: InputHandler = .{ .client = client };
    _ = try client_actions.apply(handler.client, .enter_copy_mode);
    const active_version = client.model.version();

    try handler.mouse(.{
        .x = std.math.maxInt(u16),
        .y = std.math.maxInt(u16),
        .kind = .scroll_up,
    });

    try std.testing.expect(client.model.copyModeActive());
    try std.testing.expectEqualDeep(active_version, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);

    try std.testing.expect(model.removePane(TestHarness.bootstrap_pane));
    try handler.mouse(.{ .x = 0, .y = 0, .kind = .move });

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

    var handler: InputHandler = .{ .client = client };
    _ = try client_actions.apply(handler.client, .enter_copy_mode);
    try handler.key(try parseKey_module("v"));
    const version = client.model.version();

    try std.testing.expectError(
        error.ClientOutboxFull,
        handler.key(try parseKey_module("enter")),
    );

    try std.testing.expect(client.model.copyModeActive());
    try std.testing.expect(client.model.copyModeProjection().?.view.anchor != null);
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(capacity_module, @as(usize, client.runtime_transport.outbox.len));
}
