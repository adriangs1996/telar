//! Client integration tests for input: semantic keys through the keymap,
//! pastes, pointer events and attachment shelf.catalog.
const keyinput = @import("keyinput");

const cellgrid = @import("cellgrid");
const client_module = @import("telar-client");
const data = @import("model");
const core = @import("telar-core");
const keys = @import("keys.zig");
const ClientHarness = @import("ClientHarness.zig");
const PreviewShelf = @import("PreviewShelf.zig");
const fixtures = @import("fixtures.zig");
const std = @import("std");

const KeyRouter = client_module.key_router.Type;
const PiFrame = struct {
    target: data.AttachmentTarget,
    prompt: []const u8,
    id: u64,
};

const pi_test_path = "/var/folders/8x/abc/T/pi-clipboard-3f2a9c1e-7b4d-4e8f-9a0b-1c2d3e4f5a6b.png";

/// The keys a host sends for Shift+Enter in the Kitty protocol and in
/// modifyOtherKeys, then plain Enter and Ctrl+J.
const shifted_enter_keys = [_]keyinput.Key{
    .{
        .code = .enter,
        .mods = .{ .shift = true },
        .physical = .{ .value = 13 },
        .kitty = .{ .primary = 13 },
    },
    .{
        .code = .enter,
        .mods = .{ .shift = true },
    },
    .{
        .code = .enter,
    },
    .{
        .code = .{ .char = .init("j") },
        .mods = .{ .ctrl = true },
    },
};

/// A press, repeat and release of `a`, then Ctrl+C pressed and `c`
/// released, as a host that reports key events sends them.
const lifecycle_keys = [_]keyinput.Key{
    .{
        .code = .{ .char = .init("a") },
        .physical = .{ .value = 97 },
        .kitty = .{ .primary = 97 },
    },
    .{
        .code = .{ .char = .init("a") },
        .phase = .repeat,
        .physical = .{ .value = 97 },
        .kitty = .{ .primary = 97 },
    },
    .{
        .code = .{ .char = .init("a") },
        .phase = .release,
        .physical = .{ .value = 97 },
        .kitty = .{ .primary = 97 },
    },
    .{
        .code = .{ .char = .init("c") },
        .mods = .{ .ctrl = true },
        .physical = .{ .value = 99 },
        .kitty = .{ .primary = 99 },
    },
    .{
        .code = .{ .char = .init("c") },
        .phase = .release,
        .physical = .{ .value = 99 },
        .kitty = .{ .primary = 99 },
    },
};

const prefix_key: keyinput.Key = .{
    .code = .{ .char = .init("b") },
    .mods = .{ .ctrl = true },
};

test "closing a preview deletes its matching atomic image marker" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    var shelf: PreviewShelf = .{ .catalog = .init(std.testing.allocator), .reserves_rows = false };
    defer shelf.catalog.deinit();
    harness.client.attachments = shelf.port();
    try harness.bootstrap();
    const client = harness.client;
    const target = try fixtures.installTestingAttachmentTarget(client, 1);
    for (1..3) |sequence| {
        const capture = try client.gpa.create(data.Capture);
        capture.* = .{
            .request = .{ .target = target, .sequence = sequence },
            .png = try client.gpa.dupe(u8, "png"),
            .width = 2,
            .height = 2,
        };
        _ = try client.attachments.?.adopt(capture);
    }

    const pane = client.model.panes.findIn(client.model.tabs.location[client.model.tabs.active].tab_id, target.pane_id).?;
    pane.buffer.clear(.{});
    const prompt = "> [Image #1]xx[Image #2]tail";
    pane.cursor = .{
        .visible = true,
        .x = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = prompt, .style = .{} }),
        .y = 0,
    };
    const first = shelf.catalog.snapshot().items[0].id;
    const model = client.model.tabs.active;

    _ = try client_module.view_interactions.apply(client, model, .{
        .intent = .{ .attachment_dismiss = first },
        .consumed = true,
    });

    const remaining = shelf.catalog.snapshot();
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
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    var shelf: PreviewShelf = .{ .catalog = .init(std.testing.allocator), .reserves_rows = false };
    defer shelf.catalog.deinit();
    harness.client.attachments = shelf.port();
    try harness.bootstrap();
    const client = harness.client;
    const target = try fixtures.installTestingAttachmentTarget(client, 1);
    const capture = try client.gpa.create(data.Capture);
    capture.* = .{
        .request = .{ .target = target, .sequence = 1 },
        .png = try client.gpa.dupe(u8, "png"),
        .width = 2,
        .height = 2,
    };
    _ = try client.attachments.?.adopt(capture);
    const pane = client.model.panes.findIn(client.model.tabs.location[client.model.tabs.active].tab_id, target.pane_id).?;
    pane.buffer.clear(.{});
    pane.cursor = .{
        .visible = true,
        .x = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "> [Image #1]", .style = .{} }),
        .y = 0,
    };

    try keys.routeChord(client, "backspace");

    try std.testing.expectEqual(@as(u8, 0), shelf.catalog.snapshot().len);
    const pending = (try client.model.clipboard.reserve(target)).?;
    try keys.routeChord(client, "enter");
    try std.testing.expect(client.model.clipboard.capture == null);
    const completed = try fixtures.testingClipboardCapture(client, pending, "private png");

    try client_module.clipboard_capture.completeClipboardCapture(
        client,
        .{
            .execution_id = pending.id,
            .result = completed,
        },
    );

    try std.testing.expectEqual(@as(u8, 0), shelf.catalog.snapshot().len);
    try std.testing.expect(client.model.clipboard.orphan == null);
}

test "Claude marker disappearance in a committed frame retires its paired preview" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    var shelf: PreviewShelf = .{ .catalog = .init(std.testing.allocator), .reserves_rows = false };
    defer shelf.catalog.deinit();
    harness.client.attachments = shelf.port();
    try harness.bootstrap();
    const client = harness.client;
    const target = try fixtures.installTestingAttachmentProvider(client, 1, .claude);
    const capture = try client.gpa.create(data.Capture);
    capture.* = .{
        .request = .{ .target = target, .sequence = 1, .marker_policy = .stable_number },
        .png = try client.gpa.dupe(u8, "png"),
        .width = 2,
        .height = 2,
    };
    _ = try client.attachments.?.adopt(capture);
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
    try std.testing.expectEqual(@as(u8, 1), shelf.catalog.snapshot().len);
    try keys.routeChord(client, "backspace");
    try std.testing.expectEqual(@as(u8, 1), shelf.catalog.snapshot().len);

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
    try std.testing.expectEqual(@as(u8, 0), shelf.catalog.snapshot().len);
}

test "closing a Pi preview deletes its whole pasted path from the editor" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    var shelf: PreviewShelf = .{ .catalog = .init(std.testing.allocator), .reserves_rows = false };
    defer shelf.catalog.deinit();
    harness.client.attachments = shelf.port();
    try harness.bootstrap();
    const client = harness.client;
    const target = try fixtures.installTestingAttachmentProvider(client, 1, .pi);
    try adoptPiPreview(client, target);
    try commitPiFrame(client, .{ .target = target, .prompt = "> " ++ pi_test_path, .id = 1 });
    var ack_wire: [512]u8 = undefined;
    try std.testing.expectEqual(@as(u64, 1), (try harness.nextClientMessage(&ack_wire)).frame_ack.frame_id);
    const id = shelf.catalog.snapshot().items[0].id;
    const model = client.model.tabs.active;

    _ = try client_module.view_interactions.apply(client, model, .{
        .intent = .{ .attachment_dismiss = id },
        .consumed = true,
    });

    try std.testing.expectEqual(@as(u8, 0), shelf.catalog.snapshot().len);
    try harness.settle();
    var buffer: [512]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .pane_input);
    try std.testing.expectEqualStrings("\x7f" ** pi_test_path.len, message.pane_input.bytes);
}

test "a Pi path removed by a word deletion retires its preview on the next frame" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    var shelf: PreviewShelf = .{ .catalog = .init(std.testing.allocator), .reserves_rows = false };
    defer shelf.catalog.deinit();
    harness.client.attachments = shelf.port();
    try harness.bootstrap();
    const client = harness.client;
    const target = try fixtures.installTestingAttachmentProvider(client, 1, .pi);
    try adoptPiPreview(client, target);
    try commitPiFrame(client, .{ .target = target, .prompt = "> " ++ pi_test_path, .id = 1 });
    try std.testing.expectEqual(@as(u8, 1), shelf.catalog.snapshot().len);

    try keys.routeChord(client, "ctrl+w");
    try std.testing.expectEqual(@as(u8, 1), shelf.catalog.snapshot().len);
    try commitPiFrame(client, .{
        .target = target,
        .prompt = "> /var/folders/8x/abc/T/pi-clipboard-3f2a9c1e-7b4d-4e8f-9a0b-1c2d3e4f5a6b.",
        .id = 2,
    });

    try std.testing.expectEqual(@as(u8, 0), shelf.catalog.snapshot().len);
}

test "closing a preview whose marker is too many steps from the cursor keeps it and reports the limit" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    var shelf: PreviewShelf = .{ .catalog = .init(std.testing.allocator), .reserves_rows = false };
    defer shelf.catalog.deinit();
    harness.client.attachments = shelf.port();
    try harness.bootstrap();
    const client = harness.client;
    const target = try fixtures.installTestingAttachmentTarget(client, 1);
    const capture = try client.gpa.create(data.Capture);
    capture.* = .{
        .request = .{ .target = target, .sequence = 1 },
        .png = try client.gpa.dupe(u8, "png"),
        .width = 2,
        .height = 2,
    };
    _ = try client.attachments.?.adopt(capture);

    // 121 cells after the marker: one step past the navigation bound.
    const steps = data.attachment_types.max_marker_navigation_steps + 1;
    try commitWideFrame(client, .{
        .target = target,
        .prompt = "> [Image #1]" ++ "x" ** steps,
        .id = 1,
        .cols = 200,
        .visible_cursor = true,
    });
    const id = shelf.catalog.snapshot().items[0].id;

    _ = try client_module.view_interactions.apply(client, client.model.tabs.active, .{
        .intent = .{ .attachment_dismiss = id },
        .consumed = true,
    });

    try std.testing.expectEqual(@as(u8, 1), shelf.catalog.snapshot().len);
    try expectReach(client, "attachments.max_marker_navigation_steps", steps);
}

test "closing a Pi preview whose path needs more keys than one transaction keeps it and reports the limit" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    var shelf: PreviewShelf = .{ .catalog = .init(std.testing.allocator), .reserves_rows = false };
    defer shelf.catalog.deinit();
    harness.client.attachments = shelf.port();
    try harness.bootstrap();
    const client = harness.client;
    const target = try fixtures.installTestingAttachmentProvider(client, 1, .pi);
    try adoptPiPreview(client, target);

    // A custom TMPDIR past the old 128-cell bound still pairs; one Backspace
    // per cell passes the keys one pane-input transaction carries.
    const cells = data.attachment_types.max_removal_keys + 1;
    try commitWideFrame(client, .{
        .target = target,
        .prompt = "> " ++ piPathOfCells(cells),
        .id = 1,
        .cols = 120,
    });
    const id = shelf.catalog.snapshot().items[0].id;
    try std.testing.expect(shelf.catalog.find(id).?.markerPath() != null);

    _ = try client_module.view_interactions.apply(client, client.model.tabs.active, .{
        .intent = .{ .attachment_dismiss = id },
        .consumed = true,
    });

    try std.testing.expectEqual(@as(u8, 1), shelf.catalog.snapshot().len);
    try expectReach(client, "attachments.max_removal_keys", cells);
}

test "closing a Pi preview whose path is longer than the scan bound keeps it and reports the limit" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    var shelf: PreviewShelf = .{ .catalog = .init(std.testing.allocator), .reserves_rows = false };
    defer shelf.catalog.deinit();
    harness.client.attachments = shelf.port();
    try harness.bootstrap();
    const client = harness.client;
    const target = try fixtures.installTestingAttachmentProvider(client, 1, .pi);
    try adoptPiPreview(client, target);
    try commitWideFrame(client, .{
        .target = target,
        .prompt = "> " ++ piPathOfCells(data.attachments_path_marker.max_cells + 1),
        .id = 1,
        .cols = 120,
    });
    const id = shelf.catalog.snapshot().items[0].id;

    _ = try client_module.view_interactions.apply(client, client.model.tabs.active, .{
        .intent = .{ .attachment_dismiss = id },
        .consumed = true,
    });

    try std.testing.expectEqual(@as(u8, 1), shelf.catalog.snapshot().len);
    try expectReach(client, "attachments.path_marker.max_cells", null);
}

test "a Pi preview whose path is a long custom TMPDIR still deletes it whole" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    var shelf: PreviewShelf = .{ .catalog = .init(std.testing.allocator), .reserves_rows = false };
    defer shelf.catalog.deinit();
    harness.client.attachments = shelf.port();
    try harness.bootstrap();
    const client = harness.client;
    const target = try fixtures.installTestingAttachmentProvider(client, 1, .pi);
    try adoptPiPreview(client, target);

    // Past the old 128-cell bound, within the keys of one transaction.
    const cells = 200;
    try commitWideFrame(client, .{
        .target = target,
        .prompt = "> " ++ piPathOfCells(cells),
        .id = 1,
        .cols = 120,
    });
    var ack_wire: [512]u8 = undefined;
    try std.testing.expectEqual(@as(u64, 1), (try harness.nextClientMessage(&ack_wire)).frame_ack.frame_id);
    const id = shelf.catalog.snapshot().items[0].id;

    _ = try client_module.view_interactions.apply(client, client.model.tabs.active, .{
        .intent = .{ .attachment_dismiss = id },
        .consumed = true,
    });

    try std.testing.expectEqual(@as(u8, 0), shelf.catalog.snapshot().len);
    try harness.settle();
    var buffer: [1024]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .pane_input);
    try std.testing.expectEqualStrings("\x7f" ** cells, message.pane_input.bytes);
}

test "host keys use the keyboard modes received in a pane frame" {
    const cases = [_]struct { modes: keyinput.InputModes, expected: []const u8, keys: []const keyinput.Key = &shifted_enter_keys }{
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
            .keys = &lifecycle_keys,
            .expected = "\x1b[97;1;97u\x1b[97;1:2;97u\x1b[97;1:3u\x1b[99;5u\x1b[99;1:3u",
        },
        .{
            .modes = .{ .kitty_keyboard_flags = 7 },
            .keys = &lifecycle_keys,
            .expected = "\x1b[97u\x1b[97;1:2u\x1b[97;1:3u\x1b[99;5u\x1b[99;1:3u",
        },
        .{ .modes = .{}, .keys = &lifecycle_keys, .expected = "aa\x03" },
    };
    for (cases) |case| {
        var harness: ClientHarness = undefined;
        try harness.init();
        defer harness.deinit();
        try harness.bootstrap();
        var router = try client_module.key_router.build(harness.client.routerConfig());

        var payload: [128]u8 = undefined;
        const cells = [_]cellgrid.Cell{.{}};
        const snapshot = try core.encodePaneFrame(&payload, .{
            .pane_id = ClientHarness.bootstrap_pane,
            .frame_id = 1,
            .base_frame_id = 0,
            .cols = 1,
            .rows = 1,
            .input_modes = case.modes,
            .scroll = .{ .total_rows = 1, .offset = 0 },
            .spans = &.{.{ .start = 0, .cells = &cells }},
        });
        _ = try client_module.runtime_messages.handleServerMessage(harness.client, try core.decodeServer(snapshot));
        try harness.settleModelPresentation();
        try std.testing.expectEqual(keyinput.Control.continue_routing, try routeKeys(harness.client, &router, case.keys, 0));
        try harness.settle();

        var received: [128]u8 = undefined;
        var received_len: usize = 0;
        var buffer: [256]u8 = undefined;
        while (received_len < case.expected.len) {
            switch (try harness.nextClientMessage(&buffer)) {
                .pane_input => |input| {
                    try std.testing.expectEqual(ClientHarness.bootstrap_pane, input.pane_id);
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
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const adoption = try fixtures.testingConfigAdoption(1, true);
    _ = try fixtures.reloadConfiguration(&harness, adoption);
    try std.testing.expect(!client.model.sidebar_visible);
    var router = try client_module.key_router.build(client.routerConfig());
    const codepoints: keyinput.Key.KittyCodepoints = .{ .primary = 115, .base = 115 };
    const lifecycle = [_]keyinput.Key{
        .{
            .code = .{ .char = .init("s") },
            .mods = .{ .ctrl = true },
            .physical = .{ .value = 115 },
            .kitty = codepoints,
        },
        .{
            .code = .{ .char = .init("s") },
            .phase = .release,
            .physical = .{ .value = 115 },
            .kitty = codepoints,
        },
        .{
            .code = .{ .char = .init("s") },
        },
    };

    try std.testing.expectEqual(keyinput.Control.continue_routing, try routeKeys(client, &router, &lifecycle, 0));

    try std.testing.expect(client.model.sidebar_visible);
    try std.testing.expect(!router.prefixPending());
}

test "streamed paste captures target and framing while restoring its live viewport" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const tab = client.model.tabs.active;
    const other_pane: core.PaneId = @enumFromInt(11);
    try data.pane_split.split(&client.model, tab, .{ .existing_pane = ClientHarness.bootstrap_pane, .new_pane = other_pane, .location = ClientHarness.bootstrap_location, .axis = .horizontal, .area = client.geometry().area });
    try std.testing.expect(client.model.tabs.layout[tab].focusPane(ClientHarness.bootstrap_pane));
    const pane = client.model.panes.find(ClientHarness.bootstrap_pane).?;
    pane.input_modes.bracketed_paste = true;
    pane.scroll = .{
        .total_rows = @as(u32, pane.buffer.h) + 10,
        .offset = 0,
    };
    const version = client.model.version();
    const input_events = client.telemetry.metrics.input_events;
    const input_bytes = client.telemetry.metrics.input_bytes;
    const timing_count = client.telemetry.metrics.input_enqueue.count;

    _ = try client_module.paste_routing.start(client);
    try std.testing.expectEqual(ClientHarness.bootstrap_pane, client.model.pane_paste.?.pane_id);
    try std.testing.expect(client.model.pane_paste.?.bracketed_paste);
    pane.input_modes.bracketed_paste = false;
    try std.testing.expect(client.model.tabs.layout[tab].focusPane(other_pane));
    _ = try client_module.paste_routing.content(client, "pasted");
    _ = try client_module.paste_routing.finish(client);

    try std.testing.expect(!data.pane_input.pasteActive(&client.model));
    try std.testing.expectEqual(@as(u32, 10), pane.scroll.offset);
    try std.testing.expectEqual(version.viewport + 1, client.model.version().viewport);
    try fixtures.expectNonViewportVersionEqual(version, client.model.version());
    if (comptime core.enabled) {
        try std.testing.expectEqual(input_events + 3, client.telemetry.metrics.input_events);
        try std.testing.expectEqual(input_bytes + 18, client.telemetry.metrics.input_bytes);
        try std.testing.expectEqual(timing_count + 3, client.telemetry.metrics.input_enqueue.count);
    }

    try harness.settle();
    var buffer: [256]u8 = undefined;
    const viewport = try harness.nextClientMessage(&buffer);
    try std.testing.expect(viewport == .set_pane_viewport);
    try std.testing.expectEqual(ClientHarness.bootstrap_pane, viewport.set_pane_viewport.pane_id);
    try std.testing.expectEqual(@as(u32, 10), viewport.set_pane_viewport.offset);
    const input = try harness.nextClientMessage(&buffer);
    try std.testing.expect(input == .pane_input);
    try std.testing.expectEqual(ClientHarness.bootstrap_pane, input.pane_input.pane_id);
    try std.testing.expectEqualStrings("\x1b[200~pasted\x1b[201~", input.pane_input.bytes);
}

test "streamed pane paste excludes prompt and copy-mode ownership until finish" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version = client.model.version();

    _ = try client_module.paste_routing.start(client);

    try std.testing.expect(data.pane_input.pasteActive(&client.model));
    try std.testing.expect(!data.copy_mode.enter(&client.model));
    try std.testing.expect(!client_module.name_prompt.openNamePrompt(&client.model, .rename_workspace));
    try std.testing.expect(!data.copy_mode.isActive(&client.model));
    try std.testing.expect(!client.model.name_prompt.active());
    try std.testing.expectEqualDeep(version, client.model.version());

    _ = try client_module.paste_routing.finish(client);

    try std.testing.expect(!data.pane_input.pasteActive(&client.model));
    try std.testing.expect(client_module.name_prompt.openNamePrompt(&client.model, .rename_workspace));
}

test "streamed paste keeps prompt ownership and copy mode accepts no owner" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    try std.testing.expect(client_module.name_prompt.openNamePrompt(&client.model, .rename_active_tab));

    _ = try client_module.paste_routing.start(client);
    try std.testing.expect(client.model.name_prompt.currentConst().?.pasting);
    _ = try client_module.paste_routing.content(client, " one\r");
    _ = try client_module.paste_routing.finish(client);

    const prompt = client.model.name_prompt.currentConst().?;
    try std.testing.expect(!prompt.pasting);
    try std.testing.expectEqualStrings("shell one ", prompt.field.text());
    try std.testing.expect(!data.pane_input.pasteActive(&client.model));
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);

    try keys.routeChord(client, "escape");
    try std.testing.expect(!client.model.name_prompt.active());
    try std.testing.expect(data.copy_mode.enter(&client.model));

    _ = try client_module.paste_routing.start(client);
    _ = try client_module.paste_routing.content(client, "ignored");
    _ = try client_module.paste_routing.finish(client);

    try std.testing.expect(data.copy_mode.isActive(&client.model));
    try std.testing.expect(!data.pane_input.pasteActive(&client.model));
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "name prompt rejects pointer routing after host telemetry" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const pane = client.model.panes.find(ClientHarness.bootstrap_pane).?;
    pane.mouse = .{ .tracking = .normal, .sgr = true };
    const pane_view = data.tab_layout.view(
        &client.model,
        client.model.tabs.active,
        pane.id,
        client.geometry().area,
    ).?;
    try std.testing.expect(client_module.name_prompt.openNamePrompt(&client.model, .rename_active_tab));
    const version = client.model.version();
    const outbox_len = client.model.to_runtime.len;
    const mouse_events = client.telemetry.metrics.mouse_events;

    _ = try client_module.pointer_routing.apply(client, .{
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
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const pane = client.model.panes.find(ClientHarness.bootstrap_pane).?;
    pane.mouse = .{ .tracking = .normal, .sgr = true };
    pane.scroll = .{
        .total_rows = @as(u32, pane.buffer.h) + 10,
        .offset = 0,
    };
    const pane_view = data.tab_layout.view(
        &client.model,
        client.model.tabs.active,
        pane.id,
        client.geometry().area,
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

    _ = try client_module.pointer_routing.apply(client, point);
    var press = point;
    press.kind = .press;
    _ = try client_module.pointer_routing.apply(client, press);

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
    try std.testing.expectEqual(ClientHarness.bootstrap_pane, input.pane_input.pane_id);
    try std.testing.expectEqualStrings("\x1b[<0;1;1M", input.pane_input.bytes);
}

test "mouse reports preserve exact host pixels relative to pane content" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    var capabilities = client.model.host.host_capabilities;
    capabilities.cell_width_px = 10;
    capabilities.cell_height_px = 20;
    capabilities.pointer_pixels = .supported;
    try fixtures.reconcileCapabilities(&client.model, capabilities);
    const pane = client.model.panes.find(ClientHarness.bootstrap_pane).?;
    pane.mouse = .{ .tracking = .normal, .sgr = true, .pixels = true };
    const pane_view = data.tab_layout.view(
        &client.model,
        client.model.tabs.active,
        pane.id,
        client.geometry().area,
    ).?;

    _ = try client_module.pointer_routing.apply(client, .{
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
    try std.testing.expectEqual(ClientHarness.bootstrap_pane, input.pane_input.pane_id);
    try std.testing.expectEqualStrings("\x1b[<0;8;10M", input.pane_input.bytes);
}

test "alternate-screen wheel sends cursor keys to the pane under the pointer" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const model = client.model.tabs.active;
    const focused = ClientHarness.bootstrap_pane;
    const hovered: core.PaneId = @enumFromInt(20);
    try data.pane_split.split(&client.model, model, .{ .existing_pane = focused, .new_pane = hovered, .location = ClientHarness.bootstrap_location, .axis = .horizontal, .area = client.geometry().area });
    try std.testing.expect(client.model.tabs.layout[model].focusPane(focused));
    const pane = client.model.panes.findIn(client.model.tabs.location[model].tab_id, hovered).?;
    pane.input_modes = .{ .alternate_screen = true, .alternate_scroll = true };
    pane.scroll = .{ .total_rows = pane.buffer.h, .offset = 0 };
    const hovered_view = data.tab_layout.view(&client.model, model, hovered, client.geometry().area).?;
    const version = client.model.version();

    _ = try client_module.pointer_routing.apply(client, .{
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

test "focused scroll bindings target focus rather than hover and normal input restores the viewport" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    var router = try client_module.key_router.build(client.routerConfig());
    const model = client.model.tabs.active;
    const focused = ClientHarness.bootstrap_pane;
    const hovered: core.PaneId = @enumFromInt(20);
    try data.pane_split.split(&client.model, model, .{ .existing_pane = focused, .new_pane = hovered, .location = ClientHarness.bootstrap_location, .axis = .horizontal, .area = client.geometry().area });
    try std.testing.expect(client.model.tabs.layout[model].focusPane(focused));
    const pane = client.model.panes.findIn(client.model.tabs.location[model].tab_id, focused).?;
    const other = client.model.panes.findIn(client.model.tabs.location[model].tab_id, hovered).?;
    pane.scroll = .{ .total_rows = @as(u32, pane.buffer.h) + 10, .offset = 10 };
    other.scroll = .{ .total_rows = @as(u32, other.buffer.h) + 10, .offset = 10 };
    const hovered_view = data.tab_layout.view(&client.model, model, hovered, client.geometry().area).?;
    _ = try client_module.pointer_routing.apply(client, .{ .x = hovered_view.content.x, .y = hovered_view.content.y, .kind = .move });
    const version = client.model.version();

    try routePrefixed(client, &router, "-");

    try std.testing.expectEqual(@as(u32, 7), pane.scroll.offset);
    try std.testing.expectEqual(@as(u32, 10), other.scroll.offset);
    try std.testing.expectEqual(focused, client.model.tabs.layout[model].focused().?);
    try std.testing.expect(!data.copy_mode.isActive(&client.model));
    try std.testing.expect(client.graphics.paneVisible(focused));
    try std.testing.expectEqual(version.viewport + 1, client.model.version().viewport);
    try std.testing.expectEqual(@as(usize, 1), client.model.to_runtime.len);
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const scrolled = try harness.nextClientMessage(&buffer);
    try std.testing.expect(scrolled == .set_pane_viewport);
    try std.testing.expectEqual(focused, scrolled.set_pane_viewport.pane_id);
    try std.testing.expectEqual(@as(u32, 7), scrolled.set_pane_viewport.offset);

    try keys.routeChord(client, "x");
    try std.testing.expectEqual(@as(u32, 10), pane.scroll.offset);
    try std.testing.expect(client.graphics.paneVisible(focused));
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
    try routePrefixed(client, &router, "=");
    try std.testing.expectEqualDeep(bottom_version, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "held scroll suffixes pace both viewport directions without queued steps" {
    for ([_]bool{ true, false }) |up| {
        var harness: ClientHarness = undefined;
        try harness.init();
        defer harness.deinit();
        try harness.bootstrap();
        const client = harness.client;
        var router = try client_module.key_router.build(client.routerConfig());
        const pane = client.model.panes.find(ClientHarness.bootstrap_pane).?;
        pane.scroll = .{ .total_rows = @as(u32, pane.buffer.h) + 100, .offset = 50 };
        const suffix = kittyKey(if (up) "-" else "=", .{}, .press);
        const repeated = kittyKey(if (up) "-" else "=", .{}, .repeat);
        const release = kittyKey(if (up) "-" else "=", .{}, .release);
        const ms = std.time.ns_per_ms;

        _ = try routeKey(client, &router, prefix_key, 0);
        _ = try routeKey(client, &router, suffix, 0);
        try std.testing.expectEqual(@as(u32, if (up) 47 else 53), pane.scroll.offset);
        _ = try routeKey(client, &router, repeated, 99 * ms);
        try std.testing.expectEqual(@as(u32, if (up) 47 else 53), pane.scroll.offset);
        _ = try routeKey(client, &router, repeated, 100 * ms);
        try std.testing.expectEqual(@as(u32, if (up) 44 else 56), pane.scroll.offset);

        for (0..20) |_| {
            _ = try routeKey(client, &router, repeated, 1000 * ms);
        }

        try std.testing.expectEqual(@as(u32, if (up) 41 else 59), pane.scroll.offset);
        const version = client.model.version();
        const pending = client.model.to_runtime.len;
        _ = try routeKey(client, &router, release, 1001 * ms);
        _ = try routeKey(client, &router, repeated, 2000 * ms);
        try std.testing.expectEqualDeep(version, client.model.version());
        try std.testing.expectEqual(pending, client.model.to_runtime.len);
        try std.testing.expect(router.bindingDeadline() == null);

        _ = try routeKey(client, &router, prefix_key, 2001 * ms);
        _ = try routeKey(client, &router, suffix, 2001 * ms);
        try std.testing.expectEqual(@as(u32, if (up) 38 else 62), pane.scroll.offset);
        pane.scroll.offset = if (up) 0 else 100;
        const at_edge = client.model.version();
        _ = try routeKey(client, &router, repeated, 2101 * ms);
        try std.testing.expectEqualDeep(at_edge, client.model.version());
    }
}

test "a held global scroll cannot move a newly focused pane or resume after returning" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const model = client.model.tabs.active;
    const focused = ClientHarness.bootstrap_pane;
    const second: core.PaneId = @enumFromInt(20);
    try data.pane_split.split(&client.model, model, .{ .existing_pane = focused, .new_pane = second, .location = ClientHarness.bootstrap_location, .axis = .horizontal, .area = client.geometry().area });
    try std.testing.expect(client.model.tabs.layout[model].focusPane(focused));
    const pane = client.model.panes.findIn(client.model.tabs.location[model].tab_id, focused).?;
    const other = client.model.panes.findIn(client.model.tabs.location[model].tab_id, second).?;
    pane.scroll = .{ .total_rows = @as(u32, pane.buffer.h) + 100, .offset = 100 };
    other.scroll = .{ .total_rows = @as(u32, other.buffer.h) + 100, .offset = 100 };
    const binding = try data.config_values.ConfiguredBinding.parse(&.{"alt+-"}, .{ .scroll_pane = .up });
    var router = try KeyRouter.init(&.{binding});
    const repeated = kittyKey("-", .{ .alt = true }, .repeat);

    _ = try routeKey(client, &router, kittyKey("-", .{ .alt = true }, .press), 0);
    _ = try routeKey(client, &router, repeated, 100 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u32, 94), pane.scroll.offset);
    try std.testing.expect(client.model.tabs.layout[model].focusPane(second));
    _ = try routeKey(client, &router, repeated, 200 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u32, 100), other.scroll.offset);
    try std.testing.expect(client.model.tabs.layout[model].focusPane(focused));
    _ = try routeKey(client, &router, repeated, 300 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u32, 94), pane.scroll.offset);
    try std.testing.expectEqual(@as(u32, 100), other.scroll.offset);
}

test "copy mode takes authority away from a held scroll binding" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    var router = try client_module.key_router.build(client.routerConfig());
    const pane = client.model.panes.find(ClientHarness.bootstrap_pane).?;
    pane.scroll = .{ .total_rows = @as(u32, pane.buffer.h) + 100, .offset = 100 };

    _ = try routeKey(client, &router, prefix_key, 0);
    _ = try routeKey(client, &router, kittyKey("-", .{}, .press), 0);
    _ = try client_module.actions.executeAction(client, .enter_copy_mode, .effect);
    const version = client.model.version();
    _ = try routeKey(client, &router, kittyKey("-", .{}, .repeat), 100 * std.time.ns_per_ms);
    try std.testing.expect(data.copy_mode.isActive(&client.model));
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(@as(u32, 97), pane.scroll.offset);
}

test "focused scroll bindings emit unmodified SGR wheel reports in cells or pixels" {
    for ([_]bool{ false, true }) |pixels| {
        var harness: ClientHarness = undefined;
        try harness.init();
        defer harness.deinit();
        try harness.bootstrap();
        const client = harness.client;
        var router = try client_module.key_router.build(client.routerConfig());
        var capabilities = client.model.host.host_capabilities;
        capabilities.cell_width_px = 10;
        capabilities.cell_height_px = 20;
        capabilities.pointer_pixels = .supported;
        try fixtures.reconcileCapabilities(&client.model, capabilities);
        const pane = client.model.panes.find(ClientHarness.bootstrap_pane).?;
        pane.mouse = .{ .tracking = .normal, .sgr = true, .pixels = pixels };
        pane.input_modes = .{ .alternate_screen = true, .alternate_scroll = true };
        pane.scroll = .{ .total_rows = @as(u32, pane.buffer.h) + 10, .offset = 2 };
        pane.cursor = .{ .visible = true, .x = 5, .y = 3 };
        const version = client.model.version();

        for ([_]data.ScrollDirection{ .up, .down }) |direction| {
            try routePrefixed(client, &router, if (direction == .up) "-" else "=");
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
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const pane = client.model.panes.find(ClientHarness.bootstrap_pane).?;
    pane.mouse = .{ .tracking = .normal, .sgr = true };
    const binding = try data.config_values.ConfiguredBinding.parse(&.{"alt+-"}, .{ .scroll_pane = .up });
    var router = try KeyRouter.init(&.{binding});
    const version = client.model.version();
    const repeated = kittyKey("-", .{ .alt = true }, .repeat);
    const ms = std.time.ns_per_ms;

    _ = try routeKey(client, &router, kittyKey("-", .{ .alt = true }, .press), 0);
    _ = try routeKey(client, &router, repeated, 99 * ms);
    _ = try routeKey(client, &router, repeated, 100 * ms);
    _ = try routeKey(client, &router, repeated, 100 * ms);
    _ = try routeKey(client, &router, kittyKey("-", .{}, .release), 200 * ms);
    _ = try routeKey(client, &router, repeated, 200 * ms);
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
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const model = client.model.tabs.active;
    const focused = ClientHarness.bootstrap_pane;
    const hovered: core.PaneId = @enumFromInt(20);
    try data.pane_split.split(&client.model, model, .{ .existing_pane = focused, .new_pane = hovered, .location = ClientHarness.bootstrap_location, .axis = .horizontal, .area = client.geometry().area });
    try std.testing.expect(client.model.tabs.layout[model].focusPane(focused));
    const pane = client.model.panes.findIn(client.model.tabs.location[model].tab_id, focused).?;
    pane.input_modes = .{ .alternate_screen = true, .alternate_scroll = true };
    pane.scroll = .{ .total_rows = pane.buffer.h, .offset = 0 };
    const hovered_view = data.tab_layout.view(&client.model, model, hovered, client.geometry().area).?;
    _ = try client_module.pointer_routing.apply(client, .{ .x = hovered_view.content.x, .y = hovered_view.content.y, .kind = .move });
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
    var harness: ClientHarness = undefined;
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
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    var router = try client_module.key_router.build(client.routerConfig());
    const pane = client.model.panes.find(ClientHarness.bootstrap_pane).?;
    pane.scroll = .{ .total_rows = @as(u32, pane.buffer.h) + 10, .offset = 10 };
    _ = try client_module.actions.executeAction(client, .enter_copy_mode, .effect);
    try keys.routeChord(client, "g");
    try std.testing.expectEqual(@as(u32, 0), pane.scroll.offset);
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const copied = try harness.nextClientMessage(&buffer);
    try std.testing.expect(copied == .set_pane_viewport);
    try std.testing.expectEqual(@as(u32, 0), copied.set_pane_viewport.offset);

    try routePrefixed(client, &router, "-");

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
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    // Bootstrap synced focus while the pane had focus events off: the focus
    // is remembered, no byte was sent.
    try std.testing.expectEqual(ClientHarness.bootstrap_pane, fixtures.reportedPaneId(client));
    try std.testing.expect(!client.model.reported_pane_focus.?.focus_events);

    const model = client.model.tabs.active;
    client.model.panes.findIn(client.model.tabs.location[model].tab_id, ClientHarness.bootstrap_pane).?.input_modes.focus_events = true;
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
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.panes.find(ClientHarness.bootstrap_pane).?.input_modes.focus_events = true;
    _ = data.pane_focus.syncReported(&client.model).?;
    const version = client.model.version();
    const outbox_len = client.model.to_runtime.len;

    try std.testing.expect(data.pane_focus.forgetReported(&client.model));
    try std.testing.expect(!data.pane_focus.forgetReported(&client.model));

    try std.testing.expect(client.model.reported_pane_focus == null);
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(outbox_len, client.model.to_runtime.len);
}

test "one host batch observes a prompt opened by its preceding binding" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    var router = try client_module.key_router.build(client.routerConfig());
    const batch = [_]keyinput.Key{
        prefix_key,
        .plain(.{ .char = .init("T") }),
        .plain(.{ .char = .init("x") }),
        .plain(.{ .char = .init("y") }),
        .plain(.{ .char = .init("z") }),
    };

    _ = try routeKeys(client, &router, &batch, 1);

    try std.testing.expectEqualStrings("shellxyz", client.model.name_prompt.currentConst().?.field.text());
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "detach stops a host batch before its remaining text reaches the pane" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    var router = try client_module.key_router.build(client.routerConfig());
    const before = client.telemetry.metrics.input_events;
    const batch = [_]keyinput.Key{
        prefix_key,
        .plain(.{ .char = .init("d") }),
        .plain(.{ .char = .init("i") }),
        .plain(.{ .char = .init("g") }),
        .plain(.{ .char = .init("n") }),
    };

    const control = try routeKeys(client, &router, &batch, 1);

    try std.testing.expectEqual(.stop, control);
    try std.testing.expectEqual(before, client.telemetry.metrics.input_events);
}

fn adoptPiPreview(client: *client_module.Client, target: data.AttachmentTarget) !void {
    const capture = try client.gpa.create(data.Capture);
    capture.* = .{
        .request = .{ .target = target, .sequence = 1, .marker_policy = .pasted_path },
        .png = try client.gpa.dupe(u8, "png"),
        .width = 2,
        .height = 2,
    };
    _ = try client.attachments.?.adopt(capture);
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

/// One prompt frame laid out as Pi's editor wraps: rows of `cols - 1`
/// cells, broken at any grapheme. The cursor follows the prompt, shown by
/// the terminal or, as Pi draws it, as one inverse-video cell.
const WideFrame = struct {
    target: data.AttachmentTarget,
    prompt: []const u8,
    id: u64,
    cols: u16,
    visible_cursor: bool = false,
};

fn commitWideFrame(client: *client_module.Client, input: WideFrame) !void {
    const width = input.cols - 1;
    const rows: u16 = @intCast(input.prompt.len / width + 2);
    var pane_buffer = try cellgrid.Buffer.init(std.testing.allocator, input.cols, rows);
    defer pane_buffer.deinit();
    for (input.prompt, 0..) |byte, index| {
        pane_buffer.setCell(
            .{
                .x = @intCast(index % width),
                .y = @intCast(index / width),
            },
            .{
                .text = &.{byte},
                .width = 1,
                .style = .{},
            },
        );
    }

    const cursor: core.Cursor = .{
        .visible = input.visible_cursor,
        .x = @intCast(input.prompt.len % width),
        .y = @intCast(input.prompt.len / width),
    };
    if (!input.visible_cursor) {
        pane_buffer.setCell(.{ .x = cursor.x, .y = cursor.y }, .{ .text = " ", .width = 1, .style = .{ .flags = .{ .inverse = true } } });
    }

    var payload: [64 * 1024]u8 = undefined;
    const frame = try core.encodePaneFrame(&payload, .{
        .pane_id = input.target.pane_id,
        .frame_id = input.id,
        .base_frame_id = 0,
        .cols = pane_buffer.w,
        .rows = pane_buffer.h,
        .cursor = if (input.visible_cursor) cursor else .{ .visible = false, .x = 0, .y = 0 },
        .scroll = .{ .total_rows = pane_buffer.h, .offset = 0 },
        .spans = &.{.{ .start = 0, .cells = pane_buffer.cells }},
    });

    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(frame));
}

/// A Pi clipboard path of exactly `cells` cells with the test marker's name.
fn piPathOfCells(comptime cells: usize) *const [cells]u8 {
    const file = comptime pi_test_path[std.mem.lastIndexOfScalar(u8, pi_test_path, '/').?..];
    return comptime "/" ++ ("d" ** (cells - file.len - 1)) ++ file;
}

/// The client recorded one reach of `name` asking for `requested`.
fn expectReach(client: *client_module.Client, name: []const u8, requested: ?u64) !void {
    const reaches = &client.model.limit_reaches;
    const row = reaches.find(name) orelse return error.LimitNotReported;
    try std.testing.expectEqual(@as(u64, 1), reaches.hits[row]);
    try std.testing.expectEqual(requested, reaches.requested[row]);
}

/// The prefix and one plain suffix through the keymap, as presses only.
/// Example: `try routePrefixed(client, &router, "-");`
fn routePrefixed(client: *client_module.Client, router: *KeyRouter, suffix: []const u8) !void {
    const sequence = [_]keyinput.Key{
        prefix_key,
        .plain(.{ .char = .init(suffix) }),
    };

    try std.testing.expectEqual(keyinput.Control.continue_routing, try routeKeys(client, router, &sequence, 0));
}

/// One key a host reports with Kitty event types: its codepoint doubles as
/// its physical identity.
fn kittyKey(text: []const u8, mods: keyinput.Key.Mods, phase: keyinput.Key.Phase) keyinput.Key {
    const codepoint: u32 = text[0];

    return .{
        .code = .{ .char = .init(text) },
        .mods = mods,
        .phase = phase,
        .physical = .{ .value = codepoint },
        .kitty = .{ .primary = codepoint, .base = codepoint },
    };
}

/// Routes keys in order until a binding stops the client, as a host routes
/// one batch of input.
/// Example: `const control = try routeKeys(client, &router, &keys, now_ns);`
fn routeKeys(client: *client_module.Client, router: *KeyRouter, sequence: []const keyinput.Key, now_ns: u64) !keyinput.Control {
    for (sequence) |key| {
        if (try routeKey(client, router, key, now_ns) == .stop) {
            return .stop;
        }
    }

    return .continue_routing;
}

/// Resolves one semantic key through the keymap and executes its decision,
/// as a window-less adapter does.
/// Example: `_ = try routeKey(client, &router, key, now_ns);`
fn routeKey(client: *client_module.Client, router: *KeyRouter, key: keyinput.Key, now_ns: u64) !keyinput.Control {
    errdefer router.eventFailed(key);

    const decision = router.routeEvent(.{
        .key = key,
        .now_ns = now_ns,
    }, .{
        .captures_keys = data.key_routing.captures(client_module.key_routing.keyRoutingAuthority(client)),
        .repeat_policy = if (router.repeatAction()) |held| client_module.repeatPolicy(held, client_module.actions.repeatPane(client)) else null,
    });

    switch (decision) {
        .forward => |value| _ = try client_module.key_routing.routeKeyInput(client, .{ .key = value }),
        .replay => |value| {
            for (value.held_keys[0..value.held_key_len]) |held| {
                _ = try client_module.key_routing.routeKeyInput(client, .{ .key = held });
            }

            if (value.current_key) |current| {
                _ = try client_module.key_routing.routeKeyInput(client, .{ .key = current });
            }
        },
        .action => |request| {
            const control = try client_module.actions.executeAction(client, request.value, .binding);
            if (control == .continue_routing) {
                router.actionCompleted(request, client_module.repeatPolicy(request.value, client_module.actions.repeatPane(client)));
            }

            return control;
        },
        .pending, .discard => {},
    }

    return .continue_routing;
}

