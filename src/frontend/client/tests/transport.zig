//! Client integration tests for transport.

const TerminalClient = @import("../TerminalClient.zig");
const host = TerminalClient.of;
const TestHarness = @import("TestHarness.zig");
const ChunkType = @import("../controllers/input/Chunk.zig");
const std = @import("std");
const host_inputs = @import("../controllers/input/host_inputs.zig");
const runtime_transport = @import("telar-client").runtime_io;
const capacity_module = @import("telar-client").capacity;
const encodeSystemMetrics_module = @import("telar-core").encodeSystemMetrics;
const encodeRuntimeStopping_module = @import("telar-core").encodeRuntimeStopping;
const PaneIdType = @import("telar-core").PaneId;
const request_lifecycle = @import("telar-client").request_lifecycle;
const client_startup = @import("../controllers/session/client_startup.zig");
const platform = @import("../../platform/platform.zig");
const rectSize_module = @import("telar-client").rectSize;
const InputHandler = @import("../resources/InputHandler.zig");
const kitty = @import("../../graphics/kitty.zig");
const TerminalColorsType = @import("telar-core").TerminalColors;
const encodeClientLayoutSnapshot_module = @import("telar-core").encodeClientLayoutSnapshot;
const server_messages = @import("telar-client").server_messages;
const decodeServer_module = @import("telar-core").decodeServer;
const initial_request_id = @import("telar-client").initial_request_id;
const host_capabilities = @import("../controllers/host/host_capabilities.zig");
const TabLocationType = @import("telar-core").TabLocation;
const ClientLayoutNodeType = @import("telar-core").ClientLayoutNode;
const ClientTabLayoutType = @import("telar-core").ClientTabLayout;
const ClientLayoutSnapshotType = @import("telar-core").ClientLayoutSnapshot;
const max_client_layout_wire_bytes_module = @import("telar-core").max_client_layout_wire_bytes;
const support = @import("support.zig");
const client_layout_resource = @import("telar-client").client_layouts;

test "host input arriving while no tab exists is dropped, not a crash" {
    // The workspace-handoff window: `tabs.deinit()` has run and the new
    // pane has not been confirmed. A keystroke here used to null-unwrap.
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();

    var chunk: ChunkType = .{};
    chunk.bytes[0] = 'x';
    chunk.len = 1;
    try std.testing.expect(!try host_inputs.handleRead(harness.client, chunk));
    try std.testing.expectEqual(@as(usize, 0), harness.client.runtime_transport.outbox.len);
}

test "host input reads pause at outbox capacity and resume with one token" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    try runtime_transport.enqueue(client, .{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    while (client.runtime_transport.outbox.hasCapacity()) {
        try client.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }

    try host_inputs.scheduleRead(client);
    try std.testing.expect(!host(client).host_input.read_pending);

    switch (try host(client).select.await()) {
        .sent => |result| try runtime_transport.handleSent(client, result),
        else => return error.UnexpectedEvent,
    }
    try std.testing.expectEqual(capacity_module - 1, @as(usize, client.runtime_transport.outbox.len));
    try std.testing.expect(client.runtime_transport.outbox.inFlight());
    try std.testing.expect(host(client).host_input.read_pending);

    try host_inputs.scheduleRead(client);
    try std.testing.expect(host(client).host_input.read_pending);
}

test "runtime reads own one token and do not rearm after shutdown" {
    const io = std.testing.io;
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;

    try runtime_transport.scheduleRead(client);
    try runtime_transport.scheduleRead(client);
    try std.testing.expect(client.runtime_transport.receive_pending);

    var payload: [64]u8 = undefined;
    const metrics = try encodeSystemMetrics_module(&payload, .{
        .revision = 1,
        .cpu_percent = 50,
        .memory_used_decigib = 10,
        .has_battery = false,
        .battery_percent = 0,
    });
    try harness.peer.send(io, metrics);
    switch (try host(client).select.await()) {
        .server => |result| try std.testing.expectEqual(
            @as(?u8, null),
            try runtime_transport.handleRead(client, result),
        ),
        else => return error.UnexpectedEvent,
    }
    try std.testing.expect(client.runtime_transport.receive_pending);
    try std.testing.expectEqual(@as(u64, 1), client.model.systemMetrics().?.runtime_revision);

    try harness.peer.send(io, try encodeRuntimeStopping_module(&payload));
    switch (try host(client).select.await()) {
        .server => |result| try std.testing.expectEqual(
            @as(?u8, 0),
            try runtime_transport.handleRead(client, result),
        ),
        else => return error.UnexpectedEvent,
    }
    try std.testing.expect(!client.runtime_transport.receive_pending);

    client.runtime_transport.receive_pending = true;
    try std.testing.expectError(
        error.RuntimeReadFailed,
        runtime_transport.handleRead(client, error.RuntimeReadFailed),
    );
    try std.testing.expect(!client.runtime_transport.receive_pending);
}

test "graphics credits remain owned until the outbox accepts them" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const pane_id: PaneIdType = @enumFromInt(7);
    try host(client).graphics_store.applyImage(.{
        .pane_id = pane_id,
        .revision = 1,
        .image = .{
            .key = .{ .image_id = 1, .generation = 1 },
            .format = .rgba,
            .width = 1,
            .height = 1,
            .byte_len = 4,
        },
    });
    try host(client).graphics_store.applySnapshot(.{
        .pane_id = pane_id,
        .revision = 2,
        .phase = .begin,
    });
    while (client.runtime_transport.outbox.hasCapacity()) {
        try client.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = pane_id } });
    }

    try runtime_transport.flushGraphicsCredits(client);
    try std.testing.expectEqual(@as(usize, 4), host(client).graphics_store.peekCredit().?.bytes);
    try std.testing.expect(client.runtime_transport.outbox.inFlight());

    switch (try host(client).select.await()) {
        .sent => |result| try runtime_transport.handleSent(client, result),
        else => return error.UnexpectedEvent,
    }
    try std.testing.expect(host(client).graphics_store.peekCredit() == null);
    try std.testing.expectEqual(capacity_module, @as(usize, client.runtime_transport.outbox.len));
    try std.testing.expect(client.runtime_transport.outbox.inFlight());
}

test "runtime write errors release the outbound token" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    try client.runtime_transport.outbox.push(.{
        .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane },
    });
    _ = (try client.runtime_transport.outbox.beginSend(client.runtime_transport.send_buffer)).?;

    try std.testing.expectError(
        error.RuntimeWriteFailed,
        runtime_transport.handleSent(client, error.RuntimeWriteFailed),
    );
    try std.testing.expect(!client.runtime_transport.outbox.inFlight());
    try std.testing.expectEqual(@as(u8, 1), client.runtime_transport.outbox.len);
}

test "request delivery rolls correlation back when transport is full" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    while (client.runtime_transport.outbox.hasCapacity()) {
        try client.runtime_transport.outbox.push(.{
            .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane },
        });
    }
    const request_id = try request_lifecycle.nextId(client);

    try std.testing.expectError(error.ClientOutboxFull, request_lifecycle.deliver(client, .{
        .registration = .{
            .request_id = request_id,
            .continuation = .{ .tab_snapshot = TestHarness.bootstrap_location },
        },
        .message = .{ .request_tab_snapshot = .{
            .request_id = request_id,
            .location = TestHarness.bootstrap_location,
        } },
    }));
    try std.testing.expect(request_lifecycle.consume(client, request_id) == null);
    try std.testing.expect(client.request_lifecycle.tracker.isEmpty());
}

test "client startup validates geometry before request registration" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    try host(client).view.resize(1, 1);

    try std.testing.expectError(error.TerminalTooSmall, client_startup.start(client, .{
        .resize_watcher = undefined,
    }));

    try std.testing.expect(client.request_lifecycle.tracker.isEmpty());
    try std.testing.expect(!client.runtime_transport.receive_pending);
}

test "client startup dispatches buffered host probes before awaiting its first event" {
    var tty: platform.Tty = undefined;
    var watcher = try platform.ResizeWatcher.init(&tty);
    defer watcher.deinit();
    var harness: TestHarness = undefined;
    try harness.initWithAsyncOutput(true);
    defer harness.deinit();
    const client = harness.client;

    try client_startup.start(client, .{ .resize_watcher = &watcher });

    try std.testing.expect(host(client).output.?.pending);
    try std.testing.expectEqual(@as(usize, 0), host(client).writer.end);
    try std.testing.expectEqual(@as(u8, 0), client.runtime_transport.outbox.len);
    try std.testing.expect(!host(client).host_negotiation.initial_settled);
}

test "client startup waits for runtime layout before its initial open" {
    var tty: platform.Tty = undefined;
    var watcher = try platform.ResizeWatcher.init(&tty);
    defer watcher.deinit();
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    client.options.arguments = &.{"/bin/sh"};
    const expected_size = rectSize_module(host(client).view.workbench()).?;

    try client_startup.start(client, .{
        .resize_watcher = &watcher,
    });

    try std.testing.expect(client.request_lifecycle.tracker.isEmpty());
    try std.testing.expect(client.runtime_transport.receive_pending);
    try std.testing.expect(host(client).host_input.read_pending);
    try std.testing.expectEqual(@as(u8, 0), client.runtime_transport.outbox.len);
    try std.testing.expect(!try client_startup.advance(client));
    try std.testing.expectEqual(@as(u8, 0), client.runtime_transport.outbox.len);
    var input: InputHandler = .{ .client = client };
    try input.terminalResponse(.{ .foreground_color = .{ .r = 255, .g = 255, .b = 255 } });
    try std.testing.expect(!try client_startup.advance(client));
    try std.testing.expectEqual(@as(u8, 0), client.runtime_transport.outbox.len);
    try input.terminalResponse(.{ .background_color = .{ .r = 16, .g = 16, .b = 16 } });
    try std.testing.expect(!try client_startup.advance(client));
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const configure = try harness.nextClientMessage(&buffer);
    try std.testing.expect(configure == .configure_graphics);
    try std.testing.expectEqual(
        kitty.clientSupportsSharedMemory(),
        configure.configure_graphics.shared,
    );
    const colors = try harness.nextClientMessage(&buffer);
    try std.testing.expect(colors == .configure_terminal_colors);
    try std.testing.expectEqualDeep(TerminalColorsType{
        .foreground = .{ 255, 255, 255 },
        .background = .{ 16, 16, 16 },
    }, colors.configure_terminal_colors);
    const runtime_state = try harness.nextClientMessage(&buffer);
    try std.testing.expect(runtime_state == .request_runtime_state);
    try std.testing.expectEqual(client.client_identity, runtime_state.request_runtime_state.client_identity);

    const empty_layout = try encodeClientLayoutSnapshot_module(&buffer, .{ .restored = false });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(empty_layout));
    try harness.settle();

    try std.testing.expect(request_lifecycle.has(client, .initial_open));
    const open = try harness.nextClientMessage(&buffer);
    try std.testing.expect(open == .open_pane);
    try std.testing.expectEqual(initial_request_id, open.open_pane.request_id);
    try std.testing.expectEqualDeep(expected_size, open.open_pane.size);
    try std.testing.expectEqualStrings("/", open.open_pane.launch.?.cwd);
    var arguments = open.open_pane.launch.?.arguments();
    try std.testing.expectEqualStrings("/bin/sh", (try arguments.next()).?);
    try std.testing.expect((try arguments.next()) == null);
}

test "startup timeout publishes unknown colors once and consumes late replies" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    client.startup.phase = .probing;
    _ = host(client).host_negotiation.begin(0);
    _ = try host_capabilities.handleExpiry(client, {});
    try std.testing.expect(!try client_startup.advance(client));
    try harness.settle();
    var buffer: [128]u8 = undefined;
    _ = try harness.nextClientMessage(&buffer);
    const colors = try harness.nextClientMessage(&buffer);
    try std.testing.expectEqualDeep(TerminalColorsType{}, colors.configure_terminal_colors);
    try std.testing.expect((try harness.nextClientMessage(&buffer)) == .request_runtime_state);

    var input: InputHandler = .{ .client = client };
    const revision = client.model.version();
    try input.terminalResponse(.{ .background_color = .{ .r = 16, .g = 16, .b = 16 } });
    try std.testing.expectEqualDeep(revision, client.model.version());
    try std.testing.expect(!try client_startup.advance(client));
    try std.testing.expectEqual(@as(u8, 0), client.runtime_transport.outbox.len);
}

test "startup replays early typing exactly once after pane activation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    client.startup.phase = .opening;
    const bytes = "abc\x1b]11;rgb:10/10/10\x07";
    var chunk: ChunkType = .{ .len = bytes.len };
    @memcpy(chunk.bytes[0..bytes.len], bytes);
    try std.testing.expect(!try host_inputs.handleRead(client, chunk));
    try std.testing.expectEqual(@as(u8, 0), client.runtime_transport.outbox.len);
    try harness.bootstrap();
    try std.testing.expect(!try client_startup.advance(client));
    try harness.settle();

    var buffer: [256]u8 = undefined;
    var received: [3]u8 = undefined;
    var len: usize = 0;
    while (len < received.len) {
        const message = try harness.nextClientMessage(&buffer);
        try std.testing.expectEqual(TestHarness.bootstrap_pane, message.pane_input.pane_id);
        const input = message.pane_input.bytes;
        try std.testing.expect(input.len <= received.len - len);
        @memcpy(received[len..][0..input.len], input);
        len += input.len;
    }

    try std.testing.expectEqualStrings("abc", &received);
    try std.testing.expect(!try client_startup.advance(client));
    try std.testing.expectEqual(@as(u8, 0), client.runtime_transport.outbox.len);
}

test "restored client layout controls the initial attach geometry" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(7) },
        .tab_id = @enumFromInt(9),
    };
    const pane_id: PaneIdType = @enumFromInt(44);
    const nodes = [_]ClientLayoutNodeType{.{ .pane = .{ .id = pane_id } }};
    const tabs = [_]ClientTabLayoutType{.{
        .location = location,
        .focused_pane = pane_id,
        .fullscreen = false,
        .workspace_active = true,
        .nodes = &nodes,
    }};
    const restored: ClientLayoutSnapshotType = .{
        .restored = true,
        .sidebar_visible = true,
        .sidebar_width = 50,
        .workspace_list_collapsed = true,
        .active_tab = location,
        .tabs = &tabs,
    };
    var buffer: [max_client_layout_wire_bytes_module]u8 = undefined;
    const payload = try encodeClientLayoutSnapshot_module(&buffer, restored);

    _ = try server_messages.handleServerMessage(client, try decodeServer_module(payload));
    try harness.settle();

    try std.testing.expect(client.model.sidebarVisible());
    try std.testing.expectEqual(@as(u16, 50), client.model.sidebarWidth());
    try std.testing.expect(client.model.workspaceListCollapsed());
    try std.testing.expectEqual(@as(u16, 50), host(client).view.regions.sidebar.w);
    try std.testing.expectEqual(@as(u16, 50), host(client).view.regions.top.x);
    try std.testing.expectEqual(pane_id, client.model.saved_layouts.find(location).?.pane_id);
    try std.testing.expectEqual(pane_id, client.navigation_history.find(location.workspace).?.pane_id);

    const open = try harness.nextClientMessage(&buffer);
    try std.testing.expect(open == .open_pane);
    try std.testing.expect(open.open_pane.target == .pane);
    try std.testing.expectEqual(pane_id, open.open_pane.target.pane);
    try std.testing.expect(open.open_pane.launch == null);
    try std.testing.expectEqualDeep(
        rectSize_module(host(client).view.workbench()).?,
        open.open_pane.size,
    );

    const duplicate_payload = try encodeClientLayoutSnapshot_module(&buffer, restored);
    try std.testing.expectError(
        error.DuplicateClientLayoutSnapshot,
        server_messages.handleServerMessage(client, try decodeServer_module(duplicate_payload)),
    );
}

test "sidebar preferences survive when retained pane layouts become stale" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    client.options.arguments = &.{"/bin/sh"};
    var buffer: [max_client_layout_wire_bytes_module]u8 = undefined;
    const payload = try encodeClientLayoutSnapshot_module(&buffer, .{
        .restored = true,
        .sidebar_visible = true,
        .sidebar_width = 51,
        .workspace_list_collapsed = true,
    });

    _ = try server_messages.handleServerMessage(client, try decodeServer_module(payload));
    try harness.settle();

    try std.testing.expectEqual(@as(u16, 51), client.model.sidebarWidth());
    try std.testing.expect(client.model.workspaceListCollapsed());
    const open = try harness.nextClientMessage(&buffer);
    try std.testing.expect(open == .open_pane);
    try std.testing.expect(open.open_pane.target == .default);
    try std.testing.expect(open.open_pane.launch != null);
}

test "bootstrap answers the initial open with both snapshot requests" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();

    try std.testing.expectEqual(@as(usize, 1), harness.client.model.workspace.count);
    const pane = harness.client.model.workspace.findPane(TestHarness.bootstrap_pane).?;
    try std.testing.expect(pane.attached);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, support.reportedPaneId(harness.client));
    try std.testing.expectEqual(@as(u64, 1), harness.client.model.version().workspace);
    try std.testing.expectEqual(@as(u64, 1), harness.client.model.version().tabs);
    try std.testing.expectEqual(@as(u64, 1), harness.client.model.version().active_tab);
    try std.testing.expectEqual(@as(u64, 1), harness.client.model.version().panes);
    try std.testing.expectEqualDeep(
        harness.client.model.version(),
        host(harness.client).presenter.presentation_state.prepared.model,
    );
}

test "client layout observation sends one canonical workspace update" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.workspace.active().?.snapshot_loaded = true;
    try client.client_layouts.markSnapshotReceived();
    try std.testing.expect(client.model.restoreSidebarLayout(true, 53) != null);
    try std.testing.expect(client.model.setWorkspaceListCollapsed(true) != null);

    try client_layout_resource.observe(client);
    try std.testing.expectEqual(@as(u8, 1), client.runtime_transport.outbox.len);
    try client_layout_resource.observe(client);
    try std.testing.expectEqual(@as(u8, 1), client.runtime_transport.outbox.len);
    try harness.settle();

    var buffer: [max_client_layout_wire_bytes_module]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .update_client_layout);
    const update = message.update_client_layout;
    try std.testing.expect(update.sidebar_visible);
    try std.testing.expectEqual(@as(u16, 53), update.sidebar_width);
    try std.testing.expect(update.workspace_list_collapsed);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, update.active_tab);
    try std.testing.expectEqual(@as(u16, 1), update.tab_count);
    var tabs = update.tabs();
    const tab = (try tabs.next()).?;
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, tab.location);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, tab.focused_pane);
    try std.testing.expect(tab.workspace_active);
    var nodes = tab.nodes();
    const node = (try nodes.next()).?;
    try std.testing.expectEqual(TestHarness.bootstrap_pane, node.pane.id);
    try std.testing.expect(try nodes.next() == null);
    try std.testing.expect(try tabs.next() == null);
}
