//! Client integration tests for transport.

const data = @import("model");
const client_module = @import("telar-client");
const core = @import("telar-core");
const TerminalClient = @import("../TerminalClient.zig");
const TestHarness = @import("TestHarness.zig");
const Chunk = @import("../input/Chunk.zig");
const std = @import("std");
const host_inputs = @import("../input/host_inputs.zig");
const client_startup = @import("../session/client_startup.zig");
const platform = @import("../../platform/platform.zig");
const kitty = @import("../../graphics/kitty.zig");
const host_capabilities = @import("../host/host_capabilities.zig");
const support = @import("support.zig");

test "host input arriving while no tab exists is dropped, not a crash" {
    // The workspace-handoff window: `tabs.deinit()` has run and the new
    // pane has not been confirmed. A keystroke here used to null-unwrap.
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();

    var chunk: Chunk = .{};
    chunk.bytes[0] = 'x';
    chunk.len = 1;
    try std.testing.expect(!try host_inputs.handleRead(harness.terminal, chunk));
    try std.testing.expectEqual(@as(usize, 0), harness.client.model.to_runtime.len);
}

test "host input reads pause at outbox capacity and resume with one token" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const terminal = harness.terminal;
    try client.sendRuntime(
        .{
            .detach_pane = .{
                .pane_id = TestHarness.bootstrap_pane,
            },
        },
    );
    try client.flush();
    while (client.model.to_runtime.hasCapacity()) {
        try client.model.to_runtime.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }

    try host_inputs.scheduleRead(terminal);
    try std.testing.expect(!terminal.host_input.read_pending);

    switch (try support.receiveClient(terminal)) {
        .sent => |result| try client.completeRuntimeSend(result),
        else => return error.UnexpectedEvent,
    }
    try harness.deliverHostEffects();
    try std.testing.expectEqual(data.outbox_support.capacity - 1, @as(usize, client.model.to_runtime.len));
    try std.testing.expect(client.model.to_runtime.inFlight());
    try std.testing.expect(terminal.host_input.read_pending);

    try host_inputs.scheduleRead(terminal);
    try std.testing.expect(terminal.host_input.read_pending);
}

test "runtime reads own one token and do not rearm after shutdown" {
    const io = std.testing.io;
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const terminal = harness.terminal;

    try client.startRuntimeRead();
    try client.startRuntimeRead();
    try std.testing.expect(client.runtime_transport.receive_pending);

    var payload: [64]u8 = undefined;
    const metrics = try core.encodeSystemMetrics(&payload, .{
        .revision = 1,
        .cpu_percent = 50,
        .memory_used_decigib = 10,
        .has_battery = false,
        .battery_percent = 0,
    });
    try harness.peer.send(io, metrics);
    switch (try support.receiveClient(terminal)) {
        .server => |result| try std.testing.expectEqual(
            @as(?u8, null),
            try client.receiveRuntime(result),
        ),
        else => return error.UnexpectedEvent,
    }
    try std.testing.expect(client.runtime_transport.receive_pending);
    try std.testing.expectEqual(@as(u64, 1), client.model.system_metrics.?.runtime_revision);

    try harness.peer.send(io, try core.encodeRuntimeStopping(&payload));
    switch (try support.receiveClient(terminal)) {
        .server => |result| try std.testing.expectEqual(
            @as(?u8, 0),
            try client.receiveRuntime(result),
        ),
        else => return error.UnexpectedEvent,
    }
    try std.testing.expect(!client.runtime_transport.receive_pending);

    client.runtime_transport.receive_pending = true;
    try std.testing.expectError(
        error.RuntimeReadFailed,
        client.receiveRuntime(error.RuntimeReadFailed),
    );
    try std.testing.expect(!client.runtime_transport.receive_pending);
}

test "graphics credits remain owned until the outbox accepts them" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const terminal = harness.terminal;
    const pane_id: core.PaneId = @enumFromInt(7);
    try terminal.graphics_store.applyImage(.{
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
    try terminal.graphics_store.applySnapshot(.{
        .pane_id = pane_id,
        .revision = 2,
        .phase = .begin,
    });
    while (client.model.to_runtime.hasCapacity()) {
        try client.model.to_runtime.push(.{ .detach_pane = .{ .pane_id = pane_id } });
    }

    try client.flush();
    try std.testing.expectEqual(@as(usize, 4), terminal.graphics_store.peekCredit().?.bytes);
    try std.testing.expect(client.model.to_runtime.inFlight());

    switch (try support.receiveClient(terminal)) {
        .sent => |result| try client.completeRuntimeSend(result),
        else => return error.UnexpectedEvent,
    }
    try client.flush();
    try std.testing.expect(terminal.graphics_store.peekCredit() == null);
    try std.testing.expectEqual(data.outbox_support.capacity, @as(usize, client.model.to_runtime.len));
    try std.testing.expect(client.model.to_runtime.inFlight());
}

test "runtime write errors release the outbound token" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    try client.model.to_runtime.push(.{
        .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane },
    });
    _ = (try client.model.to_runtime.beginSend(client.runtime_transport.send_buffer)).?;

    try std.testing.expectError(
        error.RuntimeWriteFailed,
        client.completeRuntimeSend(error.RuntimeWriteFailed),
    );
    try std.testing.expect(!client.model.to_runtime.inFlight());
    try std.testing.expectEqual(@as(u8, 1), client.model.to_runtime.len);
}

test "request delivery rolls correlation back when transport is full" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    while (client.model.to_runtime.hasCapacity()) {
        try client.model.to_runtime.push(.{
            .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane },
        });
    }
    const request_id = try client.model.request_lifecycle.nextId();

    try std.testing.expectError(error.ClientOutboxFull, client.sendRuntimeRequest(.{
        .registration = .{
            .request_id = request_id,
            .continuation = .{ .tab_snapshot = TestHarness.bootstrap_location },
        },
        .message = .{ .request_tab_snapshot = .{
            .request_id = request_id,
            .location = TestHarness.bootstrap_location,
        } },
    }));
    try std.testing.expect(client.model.request_lifecycle.tracker.take(request_id) == null);
    try std.testing.expect(client.model.request_lifecycle.tracker.isEmpty());
}

test "client startup validates geometry before request registration" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const terminal = harness.terminal;
    client.model.host.host_size.cols = 1;
    client.model.host.host_size.rows = 1;

    try std.testing.expectError(error.TerminalTooSmall, client_startup.start(terminal, .{
        .resize_watcher = undefined,
    }));

    try std.testing.expect(client.model.request_lifecycle.tracker.isEmpty());
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
    const terminal = harness.terminal;

    try client_startup.start(terminal, .{ .resize_watcher = &watcher });

    try std.testing.expect(terminal.output.?.pending);
    try std.testing.expectEqual(@as(usize, 0), terminal.writer.end);
    try std.testing.expectEqual(@as(u8, 0), client.model.to_runtime.len);
    try std.testing.expect(!terminal.host_negotiation.initial_settled);
}

test "client startup waits for runtime layout before its initial open" {
    var tty: platform.Tty = undefined;
    var watcher = try platform.ResizeWatcher.init(&tty);
    defer watcher.deinit();
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const terminal = harness.terminal;
    client.options.arguments = &.{"/bin/sh"};
    const expected_size = data.multiplexer.rectSize(terminal.view.workbench()).?;

    try client_startup.start(terminal, .{
        .resize_watcher = &watcher,
    });

    try std.testing.expect(client.model.request_lifecycle.tracker.isEmpty());
    try std.testing.expect(client.runtime_transport.receive_pending);
    try std.testing.expect(terminal.host_input.read_pending);
    try std.testing.expectEqual(@as(u8, 0), client.model.to_runtime.len);
    try std.testing.expect(!try client_startup.advance(terminal));
    try std.testing.expectEqual(@as(u8, 0), client.model.to_runtime.len);
    try host_inputs.terminalResponse(terminal, .{ .foreground_color = .{ .r = 255, .g = 255, .b = 255 } });
    try std.testing.expect(!try client_startup.advance(terminal));
    try std.testing.expectEqual(@as(u8, 0), client.model.to_runtime.len);
    try host_inputs.terminalResponse(terminal, .{ .background_color = .{ .r = 16, .g = 16, .b = 16 } });
    try std.testing.expect(!try client_startup.advance(terminal));
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
    try std.testing.expectEqualDeep(core.TerminalColors{
        .foreground = .{ 255, 255, 255 },
        .background = .{ 16, 16, 16 },
    }, colors.configure_terminal_colors);
    const runtime_state = try harness.nextClientMessage(&buffer);
    try std.testing.expect(runtime_state == .request_runtime_state);
    try std.testing.expectEqual(client.client_identity, runtime_state.request_runtime_state.client_identity);

    const empty_layout = try core.encodeClientLayoutSnapshot(&buffer, .{ .restored = false });
    _ = try client.handleServerMessage(try core.decodeServer(empty_layout));
    try harness.settle();

    try std.testing.expect(client.model.request_lifecycle.tracker.has(.initial_open));
    const open = try harness.nextClientMessage(&buffer);
    try std.testing.expect(open == .open_pane);
    try std.testing.expectEqual(client_module.initial_request_id, open.open_pane.request_id);
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
    const terminal = harness.terminal;
    client.model.startup.phase = .probing;
    _ = terminal.host_negotiation.begin(0);
    _ = try host_capabilities.handleExpiry(terminal, {});
    try std.testing.expect(!try client_startup.advance(terminal));
    try harness.settle();
    var buffer: [128]u8 = undefined;
    _ = try harness.nextClientMessage(&buffer);
    const colors = try harness.nextClientMessage(&buffer);
    try std.testing.expectEqualDeep(core.TerminalColors{}, colors.configure_terminal_colors);
    try std.testing.expect((try harness.nextClientMessage(&buffer)) == .request_runtime_state);

    const revision = client.model.version();
    try host_inputs.terminalResponse(terminal, .{ .background_color = .{ .r = 16, .g = 16, .b = 16 } });
    try std.testing.expectEqualDeep(revision, client.model.version());
    try std.testing.expect(!try client_startup.advance(terminal));
    try std.testing.expectEqual(@as(u8, 0), client.model.to_runtime.len);
}

test "startup replays early typing exactly once after pane activation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const terminal = harness.terminal;
    client.model.startup.phase = .opening;
    const bytes = "abc\x1b]11;rgb:10/10/10\x07";
    var chunk: Chunk = .{ .len = bytes.len };
    @memcpy(chunk.bytes[0..bytes.len], bytes);
    try std.testing.expect(!try host_inputs.handleRead(terminal, chunk));
    try std.testing.expectEqual(@as(u8, 0), client.model.to_runtime.len);
    try harness.bootstrap();
    try std.testing.expect(!try client_startup.advance(terminal));
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
    try std.testing.expect(!try client_startup.advance(terminal));
    try std.testing.expectEqual(@as(u8, 0), client.model.to_runtime.len);
}

test "restored client layout controls the initial attach geometry" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const terminal = harness.terminal;
    const location: core.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(7) },
        .tab_id = @enumFromInt(9),
    };
    const pane_id: core.PaneId = @enumFromInt(44);
    const nodes = [_]core.ClientLayoutNode{.{ .pane = .{ .id = pane_id } }};
    const tabs = [_]core.ClientTabLayout{.{
        .location = location,
        .focused_pane = pane_id,
        .fullscreen = false,
        .workspace_active = true,
        .nodes = &nodes,
    }};
    const restored: core.ClientLayoutSnapshot = .{
        .restored = true,
        .sidebar_visible = true,
        .sidebar_width = 50,
        .workspace_list_collapsed = true,
        .active_tab = location,
        .tabs = &tabs,
    };
    var buffer: [core.max_client_layout_wire_bytes]u8 = undefined;
    const payload = try core.encodeClientLayoutSnapshot(&buffer, restored);

    _ = try client.handleServerMessage(try core.decodeServer(payload));
    try harness.settle();

    try std.testing.expect(client.model.sidebar_visible);
    try std.testing.expectEqual(@as(u16, 50), client.model.sidebar_width);
    try std.testing.expect(client.model.workspace_list_collapsed);
    try std.testing.expectEqual(@as(u16, 50), terminal.view.regions.sidebar.w);
    try std.testing.expectEqual(@as(u16, 50), terminal.view.regions.top.x);
    try std.testing.expectEqual(pane_id, client.model.saved_layouts.find(location).?.pane_id);
    try std.testing.expectEqual(pane_id, client.model.navigation_history.find(location.workspace).?.pane_id);

    const open = try harness.nextClientMessage(&buffer);
    try std.testing.expect(open == .open_pane);
    try std.testing.expect(open.open_pane.target == .pane);
    try std.testing.expectEqual(pane_id, open.open_pane.target.pane);
    try std.testing.expect(open.open_pane.launch == null);
    try std.testing.expectEqualDeep(
        data.multiplexer.rectSize(terminal.view.workbench()).?,
        open.open_pane.size,
    );

    const duplicate_payload = try core.encodeClientLayoutSnapshot(&buffer, restored);
    try std.testing.expectError(
        error.DuplicateClientLayoutSnapshot,
        client.handleServerMessage(try core.decodeServer(duplicate_payload)),
    );
}

test "sidebar preferences survive when retained pane layouts become stale" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    client.options.arguments = &.{"/bin/sh"};
    var buffer: [core.max_client_layout_wire_bytes]u8 = undefined;
    const payload = try core.encodeClientLayoutSnapshot(&buffer, .{
        .restored = true,
        .sidebar_visible = true,
        .sidebar_width = 51,
        .workspace_list_collapsed = true,
    });

    _ = try client.handleServerMessage(try core.decodeServer(payload));
    try harness.settle();

    try std.testing.expectEqual(@as(u16, 51), client.model.sidebar_width);
    try std.testing.expect(client.model.workspace_list_collapsed);
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

    try std.testing.expectEqual(@as(usize, 1), harness.client.model.tabs.count);
    const pane = harness.client.model.panes.find(TestHarness.bootstrap_pane).?;
    try std.testing.expect(pane.attached);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, support.reportedPaneId(harness.client));
    try std.testing.expectEqual(@as(u64, 1), harness.client.model.version().workspace);
    try std.testing.expectEqual(@as(u64, 1), harness.client.model.version().tabs);
    try std.testing.expectEqual(@as(u64, 1), harness.client.model.version().active_tab);
    try std.testing.expectEqual(@as(u64, 1), harness.client.model.version().panes);
    try std.testing.expectEqualDeep(
        harness.client.model.version(),
        harness.terminal.presenter.presentation_state.prepared.model,
    );
}

test "client layout observation sends one canonical workspace update" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.tabs.snapshot_loaded[client.model.tabs.active] = true;
    try client.model.client_layouts.markSnapshotReceived();
    try std.testing.expect(client.model.restoreSidebarLayout(true, 53) != null);
    try std.testing.expect(client.model.setWorkspaceListCollapsed(true) != null);

    try client.synchronizeClientLayout();
    try std.testing.expectEqual(@as(u8, 1), client.model.to_runtime.len);
    try client.synchronizeClientLayout();
    try std.testing.expectEqual(@as(u8, 1), client.model.to_runtime.len);
    try harness.settle();

    var buffer: [core.max_client_layout_wire_bytes]u8 = undefined;
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
