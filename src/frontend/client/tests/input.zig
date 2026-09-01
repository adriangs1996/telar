//! Client integration tests for input.

const std = @import("std");
const core = @import("telar-core");
const agents = @import("../../agents/root.zig");
const attachments = @import("../../attachments/root.zig");
const graphics = @import("../../graphics/root.zig");
const input_capability = @import("../../input/root.zig");
const lua_config = @import("../../config/root.zig");
const notifications = @import("../../notifications/root.zig");
const platform = @import("../../platform/root.zig");
const plugin_broker = @import("../../plugins/root.zig");
const presentation = @import("../../presentation/root.zig");
const sound_capability = @import("../../sound/root.zig");
const workspace_capability = @import("../../workspace/root.zig");
const keybind = input_capability.keybind;
const kitty = graphics.kitty;

const Io = std.Io;
const File = Io.File;
const schema = core.schema;
const term = presentation.screen;

const Client = @import("../client.zig");
const InputHandler = @import("../resources/input_handler.zig");
const active_pane_resources = @import("../controllers/panes/active_pane_resources.zig");
const client_actions = @import("../controllers/input/actions.zig");
const agent_navigation = @import("../controllers/agents/agent_navigation.zig");
const agent_sounds = @import("../controllers/agents/agent_sounds.zig");
const session_application = @import("../application/session/root.zig");
const client_events = @import("../entrypoints/events.zig");
const client_startup = @import("../controllers/session/client_startup.zig");
const client_outbox = @import("../connection/outbox.zig");
const client_model = @import("../model/root.zig");
const client_telemetry = @import("../resources/telemetry.zig");
const clipboard_images = @import("../controllers/host/clipboard_images.zig");
const client_clock = @import("../resources/clock.zig");
const config_reload_worker = @import("../resources/config_reload.zig");
const config_reloads = @import("../controllers/configuration/config_reloads.zig");
const host_capabilities = @import("../controllers/host/host_capabilities.zig");
const host_inputs = @import("../controllers/input/host_inputs.zig");
const host_resizes = @import("../controllers/host/host_resizes.zig");
const name_prompts = @import("../controllers/input/name_prompts.zig");
const notification_flow = @import("../controllers/notifications/notifications.zig");
const pane_clipboards = @import("../controllers/panes/pane_clipboards.zig");
const pane_closures = @import("../controllers/panes/pane_closures.zig");
const pane_focus = @import("../controllers/panes/pane_focus.zig");
const pane_focus_reports = @import("../controllers/panes/pane_focus_reports.zig");
const pane_geometry = @import("../controllers/panes/pane_geometry.zig");
const pane_openings = @import("../controllers/panes/pane_openings.zig");
const presentation_lifecycle = @import("../presentation/presentation_lifecycle.zig");
const plugin_actions = @import("../controllers/configuration/plugin_actions.zig");
const request_lifecycle = @import("../connection/request_lifecycle.zig");
const resync_requirements = @import("../controllers/session/resync_requirements.zig");
const runtime_transport = @import("../connection/runtime_transport.zig");
const server_messages = @import("../entrypoints/runtime_messages.zig");
const sidebar_animations = @import("../controllers/notifications/sidebar_animations.zig");
const sidebar_projection = @import("../controllers/notifications/sidebar_projection.zig");
const tab_attachments = @import("../controllers/tabs/tab_attachments.zig");
const tab_closures = @import("../controllers/tabs/tab_closures.zig");
const tab_creations = @import("../controllers/tabs/tab_creations.zig");
const tab_moves = @import("../controllers/tabs/tab_moves.zig");
const tab_renames = @import("../controllers/tabs/tab_renames.zig");
const tab_snapshots = @import("../controllers/tabs/tab_snapshots.zig");
const workspace_handoffs = @import("../controllers/workspaces/workspace_handoffs.zig");
const workspace_snapshots = @import("../controllers/workspaces/workspace_snapshots.zig");
const InputChunk = Client.InputChunk;
const initial_request_id = request_lifecycle.initial_request_id;

const support = @import("support.zig");

const clientEventResourcesForTest = support.clientEventResourcesForTest;
const reportedPaneId = support.reportedPaneId;
const expectNonPromptVersionEqual = support.expectNonPromptVersionEqual;
const expectNonCopyVersionEqual = support.expectNonCopyVersionEqual;
const expectNonCopyOrViewportVersionEqual = support.expectNonCopyOrViewportVersionEqual;
const expectNonViewportVersionEqual = support.expectNonViewportVersionEqual;
const expectOnlyNotificationVersionChanged = support.expectOnlyNotificationVersionChanged;
const TestHarness = support.TestHarness;
const encodeTestingAgentSnapshot = support.encodeTestingAgentSnapshot;
const testingConfigAdoption = support.testingConfigAdoption;
const testingConfigAdoptionSource = support.testingConfigAdoptionSource;
const installTestingLuaBinding = support.installTestingLuaBinding;
const TestingPlugin = support.TestingPlugin;
const testing_plugin_context = support.testing_plugin_context;
const installTestingPlugin = support.installTestingPlugin;
const installTestingAttachmentTarget = support.installTestingAttachmentTarget;
const testingClipboardCapture = support.testingClipboardCapture;

test "host Enter variants use the keyboard modes received in a pane frame" {
    const cases = [_]struct { modes: schema.frame.InputModes, expected: []const u8 }{
        .{
            .modes = .{ .kitty_keyboard_flags = 7 },
            .expected = "\x1b[13;2u\x1b[13;2u\r\n",
        },
        .{
            .modes = .{ .modify_other_keys_2 = true },
            .expected = "\x1b[27;2;13~\x1b[27;2;13~\r\n",
        },
        .{ .modes = .{}, .expected = "\r\r\r\n" },
    };
    for (cases) |case| {
        var harness: TestHarness = undefined;
        try harness.init();
        defer harness.deinit();
        try harness.bootstrap();

        var payload: [128]u8 = undefined;
        const cells = [_]core.ui.Cell{.{}};
        const snapshot = try schema.encodePaneFrame(&payload, .{
            .pane_id = TestHarness.bootstrap_pane,
            .frame_id = 1,
            .base_frame_id = 0,
            .cols = 1,
            .rows = 1,
            .input_modes = case.modes,
            .scroll = .{ .total_rows = 1, .offset = 0 },
            .spans = &.{.{ .start = 0, .cells = &cells }},
        });
        _ = try server_messages.handleServerMessage(harness.client, try schema.decodeServer(snapshot));
        try presentation_lifecycle.observe(harness.client);
        try harness.settleModelPresentation();
        const host_bytes = "\x1b[13;2u\x1b[27;2;13~\r\n";
        var chunk: InputChunk = .{};
        @memcpy(chunk.bytes[0..host_bytes.len], host_bytes);
        chunk.len = host_bytes.len;
        try std.testing.expect(!try host_inputs.handleRead(harness.client, chunk));
        try harness.settle();

        var received: [32]u8 = undefined;
        var received_len: usize = 0;
        var buffer: [256]u8 = undefined;
        while (received_len < case.expected.len) {
            switch (try harness.nextClientMessage(&buffer)) {
                .pane_input => |input| {
                    try std.testing.expectEqual(TestHarness.bootstrap_pane, input.pane_id);
                    try std.testing.expect(input.bytes.len <= received.len - received_len);
                    @memcpy(received[received_len..][0..input.bytes.len], input.bytes);
                    received_len += input.bytes.len;
                },
                .frame_ack => {},
                else => return error.UnexpectedClientMessage,
            }
        }
        try std.testing.expectEqualStrings(case.expected, received[0..received_len]);
    }
}

test "streamed paste captures target and framing while restoring its live viewport" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const tab = &client.model.workspace.active().?.model;
    const other_pane: schema.PaneId = @enumFromInt(11);
    try tab.split(
        TestHarness.bootstrap_pane,
        other_pane,
        TestHarness.bootstrap_location,
        .horizontal,
        client.view.workbench(),
    );
    try std.testing.expect(tab.focusPane(TestHarness.bootstrap_pane));
    const pane = client.model.workspace.findPane(TestHarness.bootstrap_pane).?;
    pane.input_modes.bracketed_paste = true;
    pane.scroll = .{
        .total_rows = @as(u32, pane.buffer.h) + 10,
        .offset = 0,
    };
    const version = client.model.version();
    const pending_updates = client.presenter.pending_updates;
    const input_events = client.telemetry.metrics.input_events;
    const input_bytes = client.telemetry.metrics.input_bytes;
    const timing_count = client.telemetry.metrics.input_enqueue.count;
    var handler: InputHandler = .{ .client = client };

    try handler.pasteStart();
    try std.testing.expectEqual(TestHarness.bootstrap_pane, client.model.panePasteSession().?.pane_id);
    try std.testing.expect(client.model.panePasteSession().?.bracketed_paste);
    pane.input_modes.bracketed_paste = false;
    try std.testing.expect(tab.focusPane(other_pane));
    try handler.pasteContent("pasted");
    try handler.pasteEnd();

    try std.testing.expect(!client.model.panePasteActive());
    try std.testing.expectEqual(@as(u32, 10), pane.scroll.offset);
    try std.testing.expectEqual(version.viewport + 1, client.model.version().viewport);
    try expectNonViewportVersionEqual(version, client.model.version());
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);
    if (comptime core.diagnostics.enabled) {
        try std.testing.expectEqual(input_events + 3, client.telemetry.metrics.input_events);
        try std.testing.expectEqual(input_bytes + 18, client.telemetry.metrics.input_bytes);
        try std.testing.expectEqual(timing_count + 3, client.telemetry.metrics.input_enqueue.count);
    }

    try harness.settle();
    var buffer: [256]u8 = undefined;
    const viewport = try harness.nextClientMessage(&buffer);
    try std.testing.expect(viewport == .set_pane_viewport);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, viewport.set_pane_viewport.pane_id);
    try std.testing.expectEqual(@as(u32, 10), viewport.set_pane_viewport.offset);
    const input = try harness.nextClientMessage(&buffer);
    try std.testing.expect(input == .pane_input);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, input.pane_input.pane_id);
    try std.testing.expectEqualStrings("\x1b[200~pasted\x1b[201~", input.pane_input.bytes);
}

test "streamed pane paste excludes prompt and copy-mode ownership until finish" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version = client.model.version();
    var handler: InputHandler = .{ .client = client };

    try handler.pasteStart();

    try std.testing.expect(client.model.panePasteActive());
    try std.testing.expect(!client.model.enterCopyMode());
    try std.testing.expect(!name_prompts.beginWorkspaceRename(client));
    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expect(!client.model.name_prompt.active());
    try std.testing.expectEqualDeep(version, client.model.version());

    try handler.pasteEnd();

    try std.testing.expect(!client.model.panePasteActive());
    try std.testing.expect(name_prompts.beginWorkspaceRename(client));
}

test "streamed paste keeps prompt ownership and copy mode accepts no owner" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    var handler: InputHandler = .{ .client = client };
    try std.testing.expect(name_prompts.beginActiveTabRename(client));

    try handler.pasteStart();
    try std.testing.expect(client.model.name_prompt.currentConst().?.pasting);
    try handler.pasteContent(" one\r");
    try handler.pasteEnd();

    const prompt = client.model.name_prompt.currentConst().?;
    try std.testing.expect(!prompt.pasting);
    try std.testing.expectEqualStrings("main one ", prompt.field.text());
    try std.testing.expect(!client.model.panePasteActive());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);

    try handler.key(try keybind.parseKey("escape"));
    try std.testing.expect(!client.model.name_prompt.active());
    try std.testing.expect(client.model.enterCopyMode());

    try handler.pasteStart();
    try handler.pasteContent("ignored");
    try handler.pasteEnd();

    try std.testing.expect(client.model.copyModeActive());
    try std.testing.expect(!client.model.panePasteActive());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "name prompt rejects pointer routing after host telemetry" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const pane = client.model.workspace.findPane(TestHarness.bootstrap_pane).?;
    pane.mouse = .{ .tracking = .normal, .sgr = true };
    const pane_view = client.model.workspace.active().?.model.viewForPane(
        pane.id,
        client.view.workbench(),
    ).?;
    try std.testing.expect(name_prompts.beginActiveTabRename(client));
    const version = client.model.version();
    const outbox_len = client.runtime_transport.outbox.len;
    const mouse_events = client.telemetry.metrics.mouse_events;
    var handler: InputHandler = .{ .client = client };

    try handler.mouse(.{
        .x = pane_view.content.x,
        .y = pane_view.content.y,
        .kind = .press,
    });

    try std.testing.expect(client.model.name_prompt.active());
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(outbox_len, client.runtime_transport.outbox.len);
    if (comptime core.diagnostics.enabled) {
        try std.testing.expectEqual(mouse_events + 1, client.telemetry.metrics.mouse_events);
    }
}

test "mouse reports preserve scrollback and remain outside user-input telemetry" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const pane = client.model.workspace.findPane(TestHarness.bootstrap_pane).?;
    pane.mouse = .{ .tracking = .normal, .sgr = true };
    pane.scroll = .{
        .total_rows = @as(u32, pane.buffer.h) + 10,
        .offset = 0,
    };
    const pane_view = client.model.workspace.active().?.model.viewForPane(
        pane.id,
        client.view.workbench(),
    ).?;
    const version = client.model.version();
    const input_events = client.telemetry.metrics.input_events;
    const input_bytes = client.telemetry.metrics.input_bytes;
    const timing_count = client.telemetry.metrics.input_enqueue.count;
    const mouse_events = client.telemetry.metrics.mouse_events;
    var handler: InputHandler = .{ .client = client };
    const point: term.Event.Mouse = .{
        .x = pane_view.content.x,
        .y = pane_view.content.y,
        .kind = .move,
    };

    try handler.mouse(point);
    var press = point;
    press.kind = .press;
    try handler.mouse(press);

    try std.testing.expectEqual(@as(u32, 0), pane.scroll.offset);
    try std.testing.expectEqualDeep(version, client.model.version());
    if (comptime core.diagnostics.enabled) {
        try std.testing.expectEqual(input_events, client.telemetry.metrics.input_events);
        try std.testing.expectEqual(input_bytes, client.telemetry.metrics.input_bytes);
        try std.testing.expectEqual(timing_count, client.telemetry.metrics.input_enqueue.count);
        try std.testing.expectEqual(mouse_events + 2, client.telemetry.metrics.mouse_events);
    }

    try harness.settle();
    var buffer: [256]u8 = undefined;
    const input = try harness.nextClientMessage(&buffer);
    try std.testing.expect(input == .pane_input);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, input.pane_input.pane_id);
    try std.testing.expectEqualStrings("\x1b[<0;1;1M", input.pane_input.bytes);
}

test "mouse reports preserve exact host pixels relative to pane content" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    _ = try client.model.observeHostCapability(.{ .cell_pixels = .{
        .width = 10,
        .height = 20,
    } });
    _ = try client.model.observeHostCapability(.{ .mouse_pixels = .supported });
    const pane = client.model.workspace.findPane(TestHarness.bootstrap_pane).?;
    pane.mouse = .{ .tracking = .normal, .sgr = true, .pixels = true };
    const pane_view = client.model.workspace.active().?.model.viewForPane(
        pane.id,
        client.view.workbench(),
    ).?;
    var handler: InputHandler = .{ .client = client };

    try handler.mouse(.{
        .x = 0,
        .y = 0,
        .raw_x = @as(u32, pane_view.content.x) * 10 + 7,
        .raw_y = @as(u32, pane_view.content.y) * 20 + 9,
        .kind = .press,
    });

    try harness.settle();
    var buffer: [256]u8 = undefined;
    const input = try harness.nextClientMessage(&buffer);
    try std.testing.expect(input == .pane_input);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, input.pane_input.pane_id);
    try std.testing.expectEqualStrings("\x1b[<0;8;10M", input.pane_input.bytes);
}

test "alternate-screen wheel sends cursor keys to the pane under the pointer" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const model = &client.model.workspace.active().?.model;
    const focused = TestHarness.bootstrap_pane;
    const hovered: schema.PaneId = @enumFromInt(20);
    try model.split(
        focused,
        hovered,
        TestHarness.bootstrap_location,
        .horizontal,
        client.view.workbench(),
    );
    try std.testing.expect(model.focusPane(focused));
    const pane = model.find(hovered).?;
    pane.input_modes = .{ .alternate_screen = true, .alternate_scroll = true };
    pane.scroll = .{ .total_rows = pane.buffer.h, .offset = 0 };
    const hovered_view = model.viewForPane(hovered, client.view.workbench()).?;
    const version = client.model.version();
    var handler: InputHandler = .{ .client = client };

    try handler.mouse(.{
        .x = hovered_view.content.x,
        .y = hovered_view.content.y,
        .kind = .scroll_up,
    });

    try std.testing.expectEqual(focused, model.layout.focused().?);
    try std.testing.expectEqual(@as(u32, 0), pane.scroll.offset);
    try std.testing.expectEqualDeep(version, client.model.version());
    try harness.settle();

    var buffer: [256]u8 = undefined;
    var received: [9]u8 = undefined;
    var received_len: usize = 0;
    while (received_len < received.len) {
        const input = try harness.nextClientMessage(&buffer);
        try std.testing.expect(input == .pane_input);
        try std.testing.expectEqual(hovered, input.pane_input.pane_id);
        try std.testing.expect(input.pane_input.bytes.len <= received.len - received_len);
        @memcpy(received[received_len..][0..input.pane_input.bytes.len], input.pane_input.bytes);
        received_len += input.pane_input.bytes.len;
    }

    try std.testing.expectEqualStrings("\x1b[A\x1b[A\x1b[A", &received);
}

test "focus reporting emits focus-in only after the pane opts in" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    // Bootstrap synced focus while the pane had focus events off: the focus
    // is remembered, no byte was sent.
    try std.testing.expectEqual(TestHarness.bootstrap_pane, reportedPaneId(client));
    try std.testing.expect(!client.model.reportedPaneFocus().?.focus_events);

    const model = &client.model.workspace.active().?.model;
    model.find(TestHarness.bootstrap_pane).?.input_modes.focus_events = true;
    const input_events = client.telemetry.metrics.input_events;
    try active_pane_resources.synchronize(client);
    try harness.settle();

    try std.testing.expect(client.model.reportedPaneFocus().?.focus_events);
    if (comptime core.diagnostics.enabled) {
        try std.testing.expectEqual(input_events, client.telemetry.metrics.input_events);
    }
    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .pane_input);
    try std.testing.expectEqualStrings("\x1b[I", message.pane_input.bytes);
}

test "canonical reported focus retirement is silent and idempotent" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.workspace.findPane(TestHarness.bootstrap_pane).?.input_modes.focus_events = true;
    _ = client.model.syncReportedPaneFocus().?;
    const version = client.model.version();
    const outbox_len = client.runtime_transport.outbox.len;

    try std.testing.expect(pane_focus_reports.retire(client) == .applied);
    try std.testing.expect(pane_focus_reports.retire(client) == .unchanged);

    try std.testing.expect(client.model.reportedPaneFocus() == null);
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(outbox_len, client.runtime_transport.outbox.len);
}
