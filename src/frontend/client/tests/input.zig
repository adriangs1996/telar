//! Client integration tests for input.
const keyinput = @import("keyinput");

const cellgrid = @import("cellgrid");
const client_module = @import("telar-client");
const data = @import("model");
const core = @import("telar-core");
const TerminalAdapter = @import("../TerminalAdapter.zig");
const TestHarness = @import("TestHarness.zig");
const support = @import("support.zig");
const std = @import("std");
const host_inputs = @import("../input/host_inputs.zig");
const presentation_lifecycle = @import("../presentation/presentation_lifecycle.zig");
const Chunk = @import("../input/Chunk.zig");

test "closing a preview deletes its matching atomic image marker" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const target = try support.installTestingAttachmentTarget(client, 1);
    for (1..3) |sequence| {
        const capture = try client.gpa.create(data.Capture);
        capture.* = .{
            .request = .{ .target = target, .sequence = sequence },
            .png = try client.gpa.dupe(u8, "png"),
            .width = 2,
            .height = 2,
        };
        _ = try terminal.view.adoptAttachment(capture);
    }
    const pane = client.model.panes.findIn(client.model.tabs.location[client.model.tabs.active].tab_id, target.pane_id).?;
    pane.buffer.clear(.{});
    const prompt = "> [Image #1]xx[Image #2]tail";
    pane.cursor = .{
        .visible = true,
        .x = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = prompt, .style = .{} }),
        .y = 0,
    };
    const first = terminal.view.kittyAttachments().snapshot().items[0].id;
    const model = client.model.tabs.active;

    _ = try client_module.view_interactions.apply(client, model, .{
        .intent = .{ .attachment_dismiss = first },
        .consumed = true,
    });

    const remaining = terminal.view.kittyAttachments().snapshot();
    try std.testing.expectEqual(@as(u8, 1), remaining.len);
    try std.testing.expectEqual(@as(u64, 2), @intFromEnum(remaining.items[0].id));
    try harness.settle();
    var buffer: [512]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .pane_input);
    try std.testing.expectEqualStrings(
        "\x1b[D\x1b[D\x1b[D\x1b[D\x1b[D\x1b[D\x1b[D\x7f\x1b[C\x1b[C\x1b[C\x1b[C\x1b[C\x1b[C\x1b[C",
        message.pane_input.bytes,
    );
}

test "child marker deletion and prompt submission retire paired previews" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const target = try support.installTestingAttachmentTarget(client, 1);
    const capture = try client.gpa.create(data.Capture);
    capture.* = .{
        .request = .{ .target = target, .sequence = 1 },
        .png = try client.gpa.dupe(u8, "png"),
        .width = 2,
        .height = 2,
    };
    _ = try terminal.view.adoptAttachment(capture);
    const pane = client.model.panes.findIn(client.model.tabs.location[client.model.tabs.active].tab_id, target.pane_id).?;
    pane.buffer.clear(.{});
    pane.cursor = .{
        .visible = true,
        .x = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "> [Image #1]", .style = .{} }),
        .y = 0,
    };

    try host_inputs.key(terminal, try keyinput.chord.parseKey("backspace"));

    try std.testing.expectEqual(@as(u8, 0), terminal.view.kittyAttachments().snapshot().len);
    const pending = (try client.model.clipboard.reserve(target)).?;
    try host_inputs.key(terminal, try keyinput.chord.parseKey("enter"));
    try std.testing.expect(client.model.clipboard.capture == null);
    const completed = try support.testingClipboardCapture(client, pending, "private png");

    try client_module.clipboard_capture.completeClipboardCapture(
        client,
        .{
            .execution_id = pending.id,
            .result = completed,
        },
    );

    try std.testing.expectEqual(@as(u8, 0), terminal.view.kittyAttachments().snapshot().len);
    try std.testing.expect(client.model.clipboard.orphan == null);
}

test "Claude marker disappearance in a committed frame retires its paired preview" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const target = try support.installTestingAttachmentProvider(client, 1, .claude);
    const capture = try client.gpa.create(data.Capture);
    capture.* = .{
        .request = .{ .target = target, .sequence = 1, .marker_policy = .stable_number },
        .png = try client.gpa.dupe(u8, "png"),
        .width = 2,
        .height = 2,
    };
    _ = try terminal.view.adoptAttachment(capture);
    var pane_buffer = try cellgrid.Buffer.init(std.testing.allocator, 40, 3);
    defer pane_buffer.deinit();
    _ = pane_buffer.writeText(pane_buffer.area(), .{ .point = .{ .x = 0, .y = 1 }, .text = "> [Image #7]", .style = .{} });
    var payload: [16 * 1024]u8 = undefined;
    const marker_frame = try core.encodePaneFrame(&payload, .{
        .pane_id = target.pane_id,
        .frame_id = 1,
        .base_frame_id = 0,
        .cols = pane_buffer.w,
        .rows = pane_buffer.h,
        .cursor = .{ .visible = true, .x = 0, .y = 1 },
        .scroll = .{ .total_rows = pane_buffer.h, .offset = 0 },
        .spans = &.{.{ .start = 0, .cells = pane_buffer.cells }},
    });

    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(marker_frame));
    try std.testing.expectEqual(@as(u8, 1), terminal.view.kittyAttachments().snapshot().len);
    try host_inputs.key(terminal, try keyinput.chord.parseKey("backspace"));
    try std.testing.expectEqual(@as(u8, 1), terminal.view.kittyAttachments().snapshot().len);

    pane_buffer.clear(.{});
    const empty_cursor = pane_buffer.writeText(pane_buffer.area(), .{ .point = .{ .x = 0, .y = 1 }, .text = "> ", .style = .{} });
    const empty_frame = try core.encodePaneFrame(&payload, .{
        .pane_id = target.pane_id,
        .frame_id = 2,
        .base_frame_id = 0,
        .cols = pane_buffer.w,
        .rows = pane_buffer.h,
        .cursor = .{ .visible = true, .x = empty_cursor, .y = 1 },
        .scroll = .{ .total_rows = pane_buffer.h, .offset = 0 },
        .spans = &.{.{ .start = 0, .cells = pane_buffer.cells }},
    });

    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(empty_frame));
    try std.testing.expectEqual(@as(u8, 0), terminal.view.kittyAttachments().snapshot().len);
}

const pi_test_path = "/var/folders/8x/abc/T/pi-clipboard-3f2a9c1e-7b4d-4e8f-9a0b-1c2d3e4f5a6b.png";

fn adoptPiPreview(terminal: *TerminalAdapter, target: data.AttachmentTarget) !void {
    const client = &terminal.app;
    const capture = try client.gpa.create(data.Capture);
    capture.* = .{
        .request = .{ .target = target, .sequence = 1, .marker_policy = .pasted_path },
        .png = try client.gpa.dupe(u8, "png"),
        .width = 2,
        .height = 2,
    };
    _ = try terminal.view.adoptAttachment(capture);
}

/// Commits one Pi editor frame: hidden hardware cursor, an inverse-video
/// cell right after `prompt` as Pi's own cursor.
fn commitPiFrame(client: *client_module.Client, input: PiFrame) !void {
    var pane_buffer = try cellgrid.Buffer.init(std.testing.allocator, 120, 3);
    defer pane_buffer.deinit();
    const cursor_x = pane_buffer.writeText(pane_buffer.area(), .{ .point = .{ .x = 0, .y = 1 }, .text = input.prompt, .style = .{} });
    pane_buffer.setCell(.{ .x = cursor_x, .y = 1 }, .{ .text = " ", .width = 1, .style = .{ .flags = .{ .inverse = true } } });
    var payload: [16 * 1024]u8 = undefined;
    const frame = try core.encodePaneFrame(&payload, .{
        .pane_id = input.target.pane_id,
        .frame_id = input.id,
        .base_frame_id = 0,
        .cols = pane_buffer.w,
        .rows = pane_buffer.h,
        .cursor = .{ .visible = false, .x = 0, .y = 0 },
        .scroll = .{ .total_rows = pane_buffer.h, .offset = 0 },
        .spans = &.{.{ .start = 0, .cells = pane_buffer.cells }},
    });

    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(frame));
}

test "closing a Pi preview deletes its whole pasted path from the editor" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const target = try support.installTestingAttachmentProvider(client, 1, .pi);
    try adoptPiPreview(terminal, target);
    try commitPiFrame(client, .{ .target = target, .prompt = "> " ++ pi_test_path, .id = 1 });
    var ack_wire: [512]u8 = undefined;
    try std.testing.expectEqual(@as(u64, 1), (try harness.nextClientMessage(&ack_wire)).frame_ack.frame_id);
    const id = terminal.view.kittyAttachments().snapshot().items[0].id;
    const model = client.model.tabs.active;

    _ = try client_module.view_interactions.apply(client, model, .{
        .intent = .{ .attachment_dismiss = id },
        .consumed = true,
    });

    try std.testing.expectEqual(@as(u8, 0), terminal.view.kittyAttachments().snapshot().len);
    try harness.settle();
    var buffer: [512]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .pane_input);
    try std.testing.expectEqualStrings("\x7f" ** pi_test_path.len, message.pane_input.bytes);
}

test "a Pi path removed by a word deletion retires its preview on the next frame" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const target = try support.installTestingAttachmentProvider(client, 1, .pi);
    try adoptPiPreview(terminal, target);
    try commitPiFrame(client, .{ .target = target, .prompt = "> " ++ pi_test_path, .id = 1 });
    try std.testing.expectEqual(@as(u8, 1), terminal.view.kittyAttachments().snapshot().len);

    try host_inputs.key(terminal, try keyinput.chord.parseKey("ctrl+w"));
    try std.testing.expectEqual(@as(u8, 1), terminal.view.kittyAttachments().snapshot().len);
    try commitPiFrame(client, .{
        .target = target,
        .prompt = "> /var/folders/8x/abc/T/pi-clipboard-3f2a9c1e-7b4d-4e8f-9a0b-1c2d3e4f5a6b.",
        .id = 2,
    });

    try std.testing.expectEqual(@as(u8, 0), terminal.view.kittyAttachments().snapshot().len);
}

test "host keys use the keyboard modes received in a pane frame" {
    const lifecycle = "\x1b[97u\x1b[97;1:2u\x1b[97;1:3u\x1b[99;5u\x1b[99;1:3u";
    const cases = [_]struct { modes: keyinput.InputModes, expected: []const u8, host: []const u8 = "\x1b[13;2u\x1b[27;2;13~\r\n" }{
        .{
            .modes = .{ .kitty_keyboard_flags = 7 },
            .expected = "\x1b[13;2u\x1b[13;2u\r\x1b[106;5u",
        },
        .{
            .modes = .{ .modify_other_keys_2 = true },
            .expected = "\x1b[27;2;13~\x1b[27;2;13~\r\n",
        },
        .{ .modes = .{}, .expected = "\r\r\r\n" },
        .{
            .modes = .{ .kitty_keyboard_flags = 27 },
            .host = lifecycle,
            .expected = "\x1b[97;1;97u\x1b[97;1:2;97u\x1b[97;1:3u\x1b[99;5u\x1b[99;1:3u",
        },
        .{
            .modes = .{ .kitty_keyboard_flags = 7 },
            .host = lifecycle,
            .expected = "\x1b[97u\x1b[97;1:2u\x1b[97;1:3u\x1b[99;5u\x1b[99;1:3u",
        },
        .{ .modes = .{}, .host = lifecycle, .expected = "aa\x03" },
    };
    for (cases) |case| {
        var harness: TestHarness = undefined;
        try harness.init();
        defer harness.deinit();
        try harness.bootstrap();

        var payload: [128]u8 = undefined;
        const cells = [_]cellgrid.Cell{.{}};
        const snapshot = try core.encodePaneFrame(&payload, .{
            .pane_id = TestHarness.bootstrap_pane,
            .frame_id = 1,
            .base_frame_id = 0,
            .cols = 1,
            .rows = 1,
            .input_modes = case.modes,
            .scroll = .{ .total_rows = 1, .offset = 0 },
            .spans = &.{.{ .start = 0, .cells = &cells }},
        });
        _ = try client_module.runtime_messages.handleServerMessage(harness.client, try core.decodeServer(snapshot));
        try presentation_lifecycle.observe(harness.terminal);
        try harness.settleModelPresentation();
        const host_bytes = case.host;
        var chunk: Chunk = .{};
        @memcpy(chunk.bytes[0..host_bytes.len], host_bytes);
        chunk.len = @intCast(host_bytes.len);
        try std.testing.expect(!try host_inputs.handleRead(harness.terminal, chunk));
        try harness.settle();

        var received: [128]u8 = undefined;
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

test "releasing the physical prefix preserves its logical sequence through client routing" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const adoption = try support.testingConfigAdoption(1, true);
    _ = try support.reloadConfiguration(terminal, adoption);
    try std.testing.expect(!client.model.sidebar_visible);

    const lifecycle =
        "\x1b[115::115;5u" ++
        "\x1b[115::115;1:3u" ++
        "s";
    var chunk: Chunk = .{};
    @memcpy(chunk.bytes[0..lifecycle.len], lifecycle);
    chunk.len = lifecycle.len;

    try std.testing.expect(!try host_inputs.handleRead(terminal, chunk));

    try std.testing.expect(client.model.sidebar_visible);
    try std.testing.expect(!terminal.host_input.router.prefixPending());
}

test "streamed paste captures target and framing while restoring its live viewport" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const tab = client.model.tabs.active;
    const other_pane: core.PaneId = @enumFromInt(11);
    try data.pane_split.split(&client.model, tab, .{ .existing_pane = TestHarness.bootstrap_pane, .new_pane = other_pane, .location = TestHarness.bootstrap_location, .axis = .horizontal, .area = terminal.view.workbench() });
    try std.testing.expect(client.model.tabs.layout[tab].focusPane(TestHarness.bootstrap_pane));
    const pane = client.model.panes.find(TestHarness.bootstrap_pane).?;
    pane.input_modes.bracketed_paste = true;
    pane.scroll = .{
        .total_rows = @as(u32, pane.buffer.h) + 10,
        .offset = 0,
    };
    const version = client.model.version();
    const pending_updates = terminal.presenter.pending_updates;
    const input_events = client.telemetry.metrics.input_events;
    const input_bytes = client.telemetry.metrics.input_bytes;
    const timing_count = client.telemetry.metrics.input_enqueue.count;

    _ = try client_module.paste_routing.start(client);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, client.model.pane_paste.?.pane_id);
    try std.testing.expect(client.model.pane_paste.?.bracketed_paste);
    pane.input_modes.bracketed_paste = false;
    try std.testing.expect(client.model.tabs.layout[tab].focusPane(other_pane));
    _ = try client_module.paste_routing.content(client, "pasted");
    _ = try client_module.paste_routing.finish(client);

    try std.testing.expect(!client.model.panePasteActive());
    try std.testing.expectEqual(@as(u32, 10), pane.scroll.offset);
    try std.testing.expectEqual(version.viewport + 1, client.model.version().viewport);
    try support.expectNonViewportVersionEqual(version, client.model.version());
    try std.testing.expectEqual(pending_updates, terminal.presenter.pending_updates);
    if (comptime core.enabled) {
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

    _ = try client_module.paste_routing.start(client);

    try std.testing.expect(client.model.panePasteActive());
    try std.testing.expect(!data.copy_mode.enter(&client.model));
    try std.testing.expect(!client_module.name_prompt.openNamePrompt(&client.model, .rename_workspace));
    try std.testing.expect(!data.copy_mode.isActive(&client.model));
    try std.testing.expect(!client.model.name_prompt.active());
    try std.testing.expectEqualDeep(version, client.model.version());

    _ = try client_module.paste_routing.finish(client);

    try std.testing.expect(!client.model.panePasteActive());
    try std.testing.expect(client_module.name_prompt.openNamePrompt(&client.model, .rename_workspace));
}

test "streamed paste keeps prompt ownership and copy mode accepts no owner" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    try std.testing.expect(client_module.name_prompt.openNamePrompt(&client.model, .rename_active_tab));

    _ = try client_module.paste_routing.start(client);
    try std.testing.expect(client.model.name_prompt.currentConst().?.pasting);
    _ = try client_module.paste_routing.content(client, " one\r");
    _ = try client_module.paste_routing.finish(client);

    const prompt = client.model.name_prompt.currentConst().?;
    try std.testing.expect(!prompt.pasting);
    try std.testing.expectEqualStrings("shell one ", prompt.field.text());
    try std.testing.expect(!client.model.panePasteActive());
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);

    try host_inputs.key(terminal, try keyinput.chord.parseKey("escape"));
    try std.testing.expect(!client.model.name_prompt.active());
    try std.testing.expect(data.copy_mode.enter(&client.model));

    _ = try client_module.paste_routing.start(client);
    _ = try client_module.paste_routing.content(client, "ignored");
    _ = try client_module.paste_routing.finish(client);

    try std.testing.expect(data.copy_mode.isActive(&client.model));
    try std.testing.expect(!client.model.panePasteActive());
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "name prompt rejects pointer routing after host telemetry" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const pane = client.model.panes.find(TestHarness.bootstrap_pane).?;
    pane.mouse = .{ .tracking = .normal, .sgr = true };
    const pane_view = data.tab_layout.view(
        &client.model,
        client.model.tabs.active,
        pane.id,
        terminal.view.workbench(),
    ).?;
    try std.testing.expect(client_module.name_prompt.openNamePrompt(&client.model, .rename_active_tab));
    const version = client.model.version();
    const outbox_len = client.model.to_runtime.len;
    const mouse_events = client.telemetry.metrics.mouse_events;

    try host_inputs.mouse(terminal, .{
        .x = pane_view.content.x,
        .y = pane_view.content.y,
        .kind = .press,
    });

    try std.testing.expect(client.model.name_prompt.active());
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(outbox_len, client.model.to_runtime.len);
    if (comptime core.enabled) {
        try std.testing.expectEqual(mouse_events + 1, client.telemetry.metrics.mouse_events);
    }
}

test "mouse reports preserve scrollback and remain outside user-input telemetry" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const pane = client.model.panes.find(TestHarness.bootstrap_pane).?;
    pane.mouse = .{ .tracking = .normal, .sgr = true };
    pane.scroll = .{
        .total_rows = @as(u32, pane.buffer.h) + 10,
        .offset = 0,
    };
    const pane_view = data.tab_layout.view(
        &client.model,
        client.model.tabs.active,
        pane.id,
        terminal.view.workbench(),
    ).?;
    const version = client.model.version();
    const input_events = client.telemetry.metrics.input_events;
    const input_bytes = client.telemetry.metrics.input_bytes;
    const timing_count = client.telemetry.metrics.input_enqueue.count;
    const mouse_events = client.telemetry.metrics.mouse_events;
    const point: keyinput.Mouse = .{
        .x = pane_view.content.x,
        .y = pane_view.content.y,
        .kind = .move,
    };

    try host_inputs.mouse(terminal, point);
    var press = point;
    press.kind = .press;
    try host_inputs.mouse(terminal, press);

    try std.testing.expectEqual(@as(u32, 0), pane.scroll.offset);
    try std.testing.expectEqualDeep(version, client.model.version());
    if (comptime core.enabled) {
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
    const terminal = harness.terminal;
    _ = try client.model.observeHostCapability(.{ .cell_pixels = .{
        .width = 10,
        .height = 20,
    } });
    _ = try client.model.observeHostCapability(.{ .pointer_pixels = .supported });
    const pane = client.model.panes.find(TestHarness.bootstrap_pane).?;
    pane.mouse = .{ .tracking = .normal, .sgr = true, .pixels = true };
    const pane_view = data.tab_layout.view(
        &client.model,
        client.model.tabs.active,
        pane.id,
        terminal.view.workbench(),
    ).?;

    try host_inputs.mouse(terminal, .{
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
    const terminal = harness.terminal;
    const model = client.model.tabs.active;
    const focused = TestHarness.bootstrap_pane;
    const hovered: core.PaneId = @enumFromInt(20);
    try data.pane_split.split(&client.model, model, .{ .existing_pane = focused, .new_pane = hovered, .location = TestHarness.bootstrap_location, .axis = .horizontal, .area = terminal.view.workbench() });
    try std.testing.expect(client.model.tabs.layout[model].focusPane(focused));
    const pane = client.model.panes.findIn(client.model.tabs.location[model].tab_id, hovered).?;
    pane.input_modes = .{ .alternate_screen = true, .alternate_scroll = true };
    pane.scroll = .{ .total_rows = pane.buffer.h, .offset = 0 };
    const hovered_view = data.tab_layout.view(&client.model, model, hovered, terminal.view.workbench()).?;
    const version = client.model.version();

    try host_inputs.mouse(terminal, .{
        .x = hovered_view.content.x,
        .y = hovered_view.content.y,
        .kind = .scroll_up,
    });

    try std.testing.expectEqual(focused, client.model.tabs.layout[model].focused().?);
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

fn testingHostInput(terminal: *TerminalAdapter, bytes: []const u8) !void {
    var chunk: Chunk = .{};
    try std.testing.expect(bytes.len <= chunk.bytes.len);
    @memcpy(chunk.bytes[0..bytes.len], bytes);
    chunk.len = @intCast(bytes.len);

    try std.testing.expect(!try host_inputs.handleRead(terminal, chunk));
}

test "focused scroll bindings target focus rather than hover and normal input restores the viewport" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const model = client.model.tabs.active;
    const focused = TestHarness.bootstrap_pane;
    const hovered: core.PaneId = @enumFromInt(20);
    try data.pane_split.split(&client.model, model, .{ .existing_pane = focused, .new_pane = hovered, .location = TestHarness.bootstrap_location, .axis = .horizontal, .area = terminal.view.workbench() });
    try std.testing.expect(client.model.tabs.layout[model].focusPane(focused));
    const pane = client.model.panes.findIn(client.model.tabs.location[model].tab_id, focused).?;
    const other = client.model.panes.findIn(client.model.tabs.location[model].tab_id, hovered).?;
    pane.scroll = .{ .total_rows = @as(u32, pane.buffer.h) + 10, .offset = 10 };
    other.scroll = .{ .total_rows = @as(u32, other.buffer.h) + 10, .offset = 10 };
    const hovered_view = data.tab_layout.view(&client.model, model, hovered, terminal.view.workbench()).?;
    try host_inputs.mouse(terminal, .{ .x = hovered_view.content.x, .y = hovered_view.content.y, .kind = .move });
    const version = client.model.version();

    try testingHostInput(terminal, "\x02-");

    try std.testing.expectEqual(@as(u32, 7), pane.scroll.offset);
    try std.testing.expectEqual(@as(u32, 10), other.scroll.offset);
    try std.testing.expectEqual(focused, client.model.tabs.layout[model].focused().?);
    try std.testing.expect(!data.copy_mode.isActive(&client.model));
    try std.testing.expect(!terminal.graphics_store.paneVisible(focused));
    try std.testing.expectEqual(version.viewport + 1, client.model.version().viewport);
    try std.testing.expectEqual(@as(usize, 1), client.model.to_runtime.len);
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const scrolled = try harness.nextClientMessage(&buffer);
    try std.testing.expect(scrolled == .set_pane_viewport);
    try std.testing.expectEqual(focused, scrolled.set_pane_viewport.pane_id);
    try std.testing.expectEqual(@as(u32, 7), scrolled.set_pane_viewport.offset);

    try host_inputs.key(terminal, try keyinput.chord.parseKey("x"));
    try std.testing.expectEqual(@as(u32, 10), pane.scroll.offset);
    try std.testing.expect(terminal.graphics_store.paneVisible(focused));
    try harness.settle();
    const restored = try harness.nextClientMessage(&buffer);
    try std.testing.expect(restored == .set_pane_viewport);
    try std.testing.expectEqual(focused, restored.set_pane_viewport.pane_id);
    try std.testing.expectEqual(@as(u32, 10), restored.set_pane_viewport.offset);
    const input = try harness.nextClientMessage(&buffer);
    try std.testing.expect(input == .pane_input);
    try std.testing.expectEqual(focused, input.pane_input.pane_id);
    try std.testing.expectEqualStrings("x", input.pane_input.bytes);

    const bottom_version = client.model.version();
    try testingHostInput(terminal, "\x02=");
    try std.testing.expectEqualDeep(bottom_version, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "held scroll suffixes pace both viewport directions without queued steps" {
    for ([_]bool{ true, false }) |up| {
        var harness: TestHarness = undefined;
        try harness.init();
        defer harness.deinit();
        try harness.bootstrap();
        const client = harness.client;
        const terminal = harness.terminal;
        const pane = client.model.panes.find(TestHarness.bootstrap_pane).?;
        pane.scroll = .{ .total_rows = @as(u32, pane.buffer.h) + 100, .offset = 50 };
        const press = if (up) "\x02\x1b[45::45;1:1u" else "\x02\x1b[61::61;1:1u";
        const repeated = if (up) "\x1b[45::45;1:2u" else "\x1b[61::61;1:2u";
        const release = if (up) "\x1b[45::45;1:3u" else "\x1b[61::61;1:3u";
        const ms = std.time.ns_per_ms;

        _ = try host_inputs.feed(terminal, .{ .bytes = press, .now_ns = 0 });
        try std.testing.expectEqual(@as(u32, if (up) 47 else 53), pane.scroll.offset);
        _ = try host_inputs.feed(terminal, .{ .bytes = repeated, .now_ns = 99 * ms });
        try std.testing.expectEqual(@as(u32, if (up) 47 else 53), pane.scroll.offset);
        _ = try host_inputs.feed(terminal, .{ .bytes = repeated, .now_ns = 100 * ms });
        try std.testing.expectEqual(@as(u32, if (up) 44 else 56), pane.scroll.offset);

        for (0..20) |_| {
            _ = try host_inputs.feed(terminal, .{ .bytes = repeated, .now_ns = 1000 * ms });
        }

        try std.testing.expectEqual(@as(u32, if (up) 41 else 59), pane.scroll.offset);
        const version = client.model.version();
        const pending = client.model.to_runtime.len;
        _ = try host_inputs.feed(terminal, .{ .bytes = release, .now_ns = 1001 * ms });
        _ = try host_inputs.feed(terminal, .{ .bytes = repeated, .now_ns = 2000 * ms });
        try std.testing.expectEqualDeep(version, client.model.version());
        try std.testing.expectEqual(pending, client.model.to_runtime.len);
        try std.testing.expect(terminal.host_input.router.inputDeadline() == null);
        try std.testing.expect(terminal.host_input.router.bindingDeadline() == null);

        _ = try host_inputs.feed(terminal, .{ .bytes = press, .now_ns = 2001 * ms });
        try std.testing.expectEqual(@as(u32, if (up) 38 else 62), pane.scroll.offset);
        pane.scroll.offset = if (up) 0 else 100;
        const at_edge = client.model.version();
        _ = try host_inputs.feed(terminal, .{ .bytes = repeated, .now_ns = 2101 * ms });
        try std.testing.expectEqualDeep(at_edge, client.model.version());
    }
}

test "a held global scroll cannot move a newly focused pane or resume after returning" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const model = client.model.tabs.active;
    const focused = TestHarness.bootstrap_pane;
    const second: core.PaneId = @enumFromInt(20);
    try data.pane_split.split(&client.model, model, .{ .existing_pane = focused, .new_pane = second, .location = TestHarness.bootstrap_location, .axis = .horizontal, .area = terminal.view.workbench() });
    try std.testing.expect(client.model.tabs.layout[model].focusPane(focused));
    const pane = client.model.panes.findIn(client.model.tabs.location[model].tab_id, focused).?;
    const other = client.model.panes.findIn(client.model.tabs.location[model].tab_id, second).?;
    pane.scroll = .{ .total_rows = @as(u32, pane.buffer.h) + 100, .offset = 100 };
    other.scroll = .{ .total_rows = @as(u32, other.buffer.h) + 100, .offset = 100 };
    const binding = try data.config_values.ConfiguredBinding.parse(&.{"alt+-"}, .{ .scroll_pane = .up });
    terminal.host_input.replaceRouter(client.io, try host_inputs.Router.init(&.{binding}));
    const repeated = "\x1b[45::45;3:2u";

    _ = try host_inputs.feed(terminal, .{ .bytes = "\x1b[45::45;3:1u", .now_ns = 0 });
    _ = try host_inputs.feed(terminal, .{ .bytes = repeated, .now_ns = 100 * std.time.ns_per_ms });
    try std.testing.expectEqual(@as(u32, 94), pane.scroll.offset);
    try std.testing.expect(client.model.tabs.layout[model].focusPane(second));
    _ = try host_inputs.feed(terminal, .{ .bytes = repeated, .now_ns = 200 * std.time.ns_per_ms });
    try std.testing.expectEqual(@as(u32, 100), other.scroll.offset);
    try std.testing.expect(client.model.tabs.layout[model].focusPane(focused));
    _ = try host_inputs.feed(terminal, .{ .bytes = repeated, .now_ns = 300 * std.time.ns_per_ms });
    try std.testing.expectEqual(@as(u32, 94), pane.scroll.offset);
    try std.testing.expectEqual(@as(u32, 100), other.scroll.offset);
}

test "copy mode takes authority away from a held scroll binding" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const pane = client.model.panes.find(TestHarness.bootstrap_pane).?;
    pane.scroll = .{ .total_rows = @as(u32, pane.buffer.h) + 100, .offset = 100 };

    _ = try host_inputs.feed(terminal, .{ .bytes = "\x02\x1b[45::45;1:1u", .now_ns = 0 });
    _ = try client_module.actions.executeAction(client, .enter_copy_mode, .effect);
    const version = client.model.version();
    _ = try host_inputs.feed(terminal, .{ .bytes = "\x1b[45::45;1:2u", .now_ns = 100 * std.time.ns_per_ms });
    try std.testing.expect(data.copy_mode.isActive(&client.model));
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(@as(u32, 97), pane.scroll.offset);
}

test "focused scroll bindings emit unmodified SGR wheel reports in cells or pixels" {
    for ([_]bool{ false, true }) |pixels| {
        var harness: TestHarness = undefined;
        try harness.init();
        defer harness.deinit();
        try harness.bootstrap();
        const client = harness.client;
        const terminal = harness.terminal;
        _ = try client.model.observeHostCapability(.{ .cell_pixels = .{ .width = 10, .height = 20 } });
        _ = try client.model.observeHostCapability(.{ .pointer_pixels = .supported });
        const pane = client.model.panes.find(TestHarness.bootstrap_pane).?;
        pane.mouse = .{ .tracking = .normal, .sgr = true, .pixels = pixels };
        pane.input_modes = .{ .alternate_screen = true, .alternate_scroll = true };
        pane.scroll = .{ .total_rows = @as(u32, pane.buffer.h) + 10, .offset = 2 };
        pane.cursor = .{ .visible = true, .x = 5, .y = 3 };
        const version = client.model.version();

        for ([_]data.ScrollDirection{ .up, .down }) |direction| {
            try testingHostInput(terminal, if (direction == .up) "\x02-" else "\x02=");
            try std.testing.expectEqualDeep(version, client.model.version());
            try std.testing.expectEqual(@as(u32, 2), pane.scroll.offset);
            try std.testing.expect(!data.copy_mode.isActive(&client.model));
            try harness.settle();
            var buffer: [256]u8 = undefined;
            const message = try harness.nextClientMessage(&buffer);
            try std.testing.expect(message == .pane_input);
            try std.testing.expectEqual(pane.id, message.pane_input.pane_id);
            const expected = if (pixels)
                (if (direction == .up) "\x1b[<64;6;11M" else "\x1b[<65;6;11M")
            else
                (if (direction == .up) "\x1b[<64;1;1M" else "\x1b[<65;1;1M");

            try std.testing.expectEqualStrings(expected, message.pane_input.bytes);
        }
    }
}

test "held global scroll paces SGR reports without forwarding the binding chord" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const pane = client.model.panes.find(TestHarness.bootstrap_pane).?;
    pane.mouse = .{ .tracking = .normal, .sgr = true };
    const binding = try data.config_values.ConfiguredBinding.parse(&.{"alt+-"}, .{ .scroll_pane = .up });
    terminal.host_input.replaceRouter(client.io, try host_inputs.Router.init(&.{binding}));
    const version = client.model.version();
    const repeated = "\x1b[45::45;3:2u";

    _ = try host_inputs.feed(terminal, .{ .bytes = "\x1b[45::45;3:1u", .now_ns = 0 });
    _ = try host_inputs.feed(terminal, .{ .bytes = repeated, .now_ns = 99 * std.time.ns_per_ms });
    _ = try host_inputs.feed(terminal, .{ .bytes = repeated ++ repeated, .now_ns = 100 * std.time.ns_per_ms });
    _ = try host_inputs.feed(terminal, .{ .bytes = "\x1b[45::45;1:3u" ++ repeated, .now_ns = 200 * std.time.ns_per_ms });
    try std.testing.expectEqualDeep(version, client.model.version());
    try harness.settle();

    const expected = "\x1b[<64;1;1M\x1b[<64;1;1M";
    var received: [expected.len]u8 = undefined;
    var received_len: usize = 0;
    var buffer: [256]u8 = undefined;
    while (received_len < received.len) {
        const message = try harness.nextClientMessage(&buffer);
        try std.testing.expect(message == .pane_input);
        try std.testing.expectEqual(pane.id, message.pane_input.pane_id);
        try std.testing.expect(message.pane_input.bytes.len > 0);
        try std.testing.expect(message.pane_input.bytes.len <= received.len - received_len);
        @memcpy(received[received_len..][0..message.pane_input.bytes.len], message.pane_input.bytes);
        received_len += message.pane_input.bytes.len;
    }

    try std.testing.expectEqualStrings(expected, &received);
}

test "focused scroll sends alternate-screen cursor keys only to the focused pane" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const model = client.model.tabs.active;
    const focused = TestHarness.bootstrap_pane;
    const hovered: core.PaneId = @enumFromInt(20);
    try data.pane_split.split(&client.model, model, .{ .existing_pane = focused, .new_pane = hovered, .location = TestHarness.bootstrap_location, .axis = .horizontal, .area = terminal.view.workbench() });
    try std.testing.expect(client.model.tabs.layout[model].focusPane(focused));
    const pane = client.model.panes.findIn(client.model.tabs.location[model].tab_id, focused).?;
    pane.input_modes = .{ .alternate_screen = true, .alternate_scroll = true };
    pane.scroll = .{ .total_rows = pane.buffer.h, .offset = 0 };
    const hovered_view = data.tab_layout.view(&client.model, model, hovered, terminal.view.workbench()).?;
    try host_inputs.mouse(terminal, .{ .x = hovered_view.content.x, .y = hovered_view.content.y, .kind = .move });
    const version = client.model.version();

    for ([_]data.ScrollDirection{ .up, .down }) |direction| {
        _ = try client_module.actions.executeAction(
            client,
            .{
                .scroll_pane = direction,
            },
            .effect,
        );
        try std.testing.expectEqualDeep(version, client.model.version());
        try std.testing.expectEqual(focused, client.model.tabs.layout[model].focused().?);
        try harness.settle();
        var buffer: [256]u8 = undefined;
        var received: [9]u8 = undefined;
        var received_len: usize = 0;

        while (received_len < received.len) {
            const message = try harness.nextClientMessage(&buffer);
            try std.testing.expect(message == .pane_input);
            try std.testing.expectEqual(focused, message.pane_input.pane_id);
            try std.testing.expect(message.pane_input.bytes.len > 0);
            try std.testing.expect(message.pane_input.bytes.len <= received.len - received_len);
            @memcpy(received[received_len..][0..message.pane_input.bytes.len], message.pane_input.bytes);
            received_len += message.pane_input.bytes.len;
        }

        try std.testing.expectEqualStrings(if (direction == .up) "\x1b[A\x1b[A\x1b[A" else "\x1b[B\x1b[B\x1b[B", &received);
    }
}

test "focused scroll without an active pane has no effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const version = client.model.version();

    _ = try client_module.actions.executeAction(
        client,
        .{
            .scroll_pane = .up,
        },
        .effect,
    );
    _ = try client_module.actions.executeAction(
        client,
        .{
            .scroll_pane = .down,
        },
        .effect,
    );

    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "focused scroll retires copy mode before moving the restored viewport" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const pane = client.model.panes.find(TestHarness.bootstrap_pane).?;
    pane.scroll = .{ .total_rows = @as(u32, pane.buffer.h) + 10, .offset = 10 };
    _ = try client_module.actions.executeAction(client, .enter_copy_mode, .effect);
    try host_inputs.key(terminal, try keyinput.chord.parseKey("g"));
    try std.testing.expectEqual(@as(u32, 0), pane.scroll.offset);
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const copied = try harness.nextClientMessage(&buffer);
    try std.testing.expect(copied == .set_pane_viewport);
    try std.testing.expectEqual(@as(u32, 0), copied.set_pane_viewport.offset);

    try testingHostInput(terminal, "\x02-");

    try std.testing.expect(!data.copy_mode.isActive(&client.model));
    try std.testing.expectEqual(@as(u32, 7), pane.scroll.offset);
    try harness.settle();
    const restored = try harness.nextClientMessage(&buffer);
    try std.testing.expect(restored == .set_pane_viewport);
    try std.testing.expectEqual(@as(u32, 10), restored.set_pane_viewport.offset);
    const scrolled = try harness.nextClientMessage(&buffer);
    try std.testing.expect(scrolled == .set_pane_viewport);
    try std.testing.expectEqual(@as(u32, 7), scrolled.set_pane_viewport.offset);
}

test "focus reporting emits focus-in only after the pane opts in" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    // Bootstrap synced focus while the pane had focus events off: the focus
    // is remembered, no byte was sent.
    try std.testing.expectEqual(TestHarness.bootstrap_pane, support.reportedPaneId(client));
    try std.testing.expect(!client.model.reported_pane_focus.?.focus_events);

    const model = client.model.tabs.active;
    client.model.panes.findIn(client.model.tabs.location[model].tab_id, TestHarness.bootstrap_pane).?.input_modes.focus_events = true;
    const input_events = client.telemetry.metrics.input_events;
    try client_module.pane_focus.synchronizeActivePane(client);
    try harness.settle();

    try std.testing.expect(client.model.reported_pane_focus.?.focus_events);
    if (comptime core.enabled) {
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
    client.model.panes.find(TestHarness.bootstrap_pane).?.input_modes.focus_events = true;
    _ = client.model.syncReportedPaneFocus().?;
    const version = client.model.version();
    const outbox_len = client.model.to_runtime.len;

    try std.testing.expect(client.model.forgetReportedPaneFocus());
    try std.testing.expect(!client.model.forgetReportedPaneFocus());

    try std.testing.expect(client.model.reported_pane_focus == null);
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(outbox_len, client.model.to_runtime.len);
}

test "native thread view action flips the focused pane surface" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();

    const client = harness.client;
    var expected_version = client.model.version();
    const active = client.model.tabs.active;
    const focused = client.model.tabs.layout[active].focused().?;
    try std.testing.expectEqual(core.PaneSurface.terminal, client.model.tabs.layout[active].surface(focused));

    for ([_]core.PaneSurface{ .thread, .terminal }) |expected_surface| {
        const control = try client_module.actions.executeAction(client, .toggle_thread_view, .effect);

        expected_version.panes +%= 1;
        try std.testing.expectEqual(keyinput.Control.continue_routing, control);
        try std.testing.expectEqual(expected_surface, client.model.tabs.layout[active].surface(focused));
        try std.testing.expectEqualDeep(expected_version, client.model.version());
    }
}

test "one host batch observes a prompt opened by its preceding binding" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;

    _ = try host_inputs.feed(terminal, .{ .bytes = "\x02Txyz", .now_ns = 1 });

    try std.testing.expectEqualStrings("shellxyz", client.model.name_prompt.currentConst().?.field.text());
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "detach stops a host batch before its remaining text reaches the pane" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const before = client.telemetry.metrics.input_events;

    const control = try host_inputs.feed(terminal, .{ .bytes = "\x02dignored", .now_ns = 1 });

    try std.testing.expectEqual(.stop, control);
    try std.testing.expectEqual(before, client.telemetry.metrics.input_events);
    try std.testing.expectEqual(@as(usize, 0), terminal.host_input.router.input_end);
}

const PiFrame = struct {
    target: data.AttachmentTarget,
    prompt: []const u8,
    id: u64,
};
