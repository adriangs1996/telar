//! Client integration tests for input.

const TestHarness = @import("TestHarness.zig");
const support = @import("support.zig");
const CaptureType = @import("telar-client").Capture;
const view_interactions = @import("../controllers/input/view_interactions.zig");
const std = @import("std");
const InputHandler = @import("../resources/InputHandler.zig");
const parseKey_module = @import("telar-client").parseKey;
const clipboard_images = @import("../controllers/host/clipboard_images.zig");
const BufferType = @import("telar-core").Buffer;
const encodePaneFrame_module = @import("telar-core").encodePaneFrame;
const server_messages = @import("../entrypoints/runtime_messages.zig");
const decodeServer_module = @import("telar-core").decodeServer;
const Client = @import("../Client.zig");
const TargetType = @import("telar-client").AttachmentTarget;
const PiFrame = @import("PiFrame.zig");
const InputModesType = @import("telar-core").InputModes;
const CellType = @import("telar-core").Cell;
const presentation_lifecycle = @import("../presentation/presentation_lifecycle.zig");
const Chunk = @import("../controllers/input/Chunk.zig");
const host_inputs = @import("../controllers/input/host_inputs.zig");
const config_reloads = @import("../controllers/configuration/config_reloads.zig");
const PaneIdType = @import("telar-core").PaneId;
const enabled_module = @import("telar-core").enabled;
const name_prompts = @import("../controllers/input/name_prompts.zig");
const term = @import("../../presentation/screen_support.zig");
const model_module = @import("../../config/model.zig");
const client_actions = @import("../controllers/input/actions.zig");
const ScrollDirectionType = @import("telar-client").ScrollDirection;
const active_pane_resources = @import("../controllers/panes/active_pane_resources.zig");
const pane_focus_reports = @import("../controllers/panes/pane_focus_reports.zig");
const PresentationModeType = @import("telar-client").PresentationMode;
const ControlType = @import("telar-client").Control;

test "closing a preview deletes its matching atomic image marker" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const target = try support.installTestingAttachmentTarget(client, 1);
    for (1..3) |sequence| {
        const capture = try client.gpa.create(CaptureType);
        capture.* = .{
            .request = .{ .target = target, .sequence = sequence },
            .png = try client.gpa.dupe(u8, "png"),
            .width = 2,
            .height = 2,
        };
        _ = try client.view.adoptAttachment(capture);
    }
    const pane = client.model.activeTabModel().?.find(target.pane_id).?;
    pane.buffer.clear(.{});
    const prompt = "> [Image #1]xx[Image #2]tail";
    pane.cursor = .{
        .visible = true,
        .x = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = prompt, .style = .{} }),
        .y = 0,
    };
    const first = client.view.kittyAttachments().snapshot().items[0].id;
    const model = client.model.activeTabModel().?;

    _ = try view_interactions.apply(client, model, .{
        .intent = .{ .attachment_dismiss = first },
        .consumed = true,
    });

    const remaining = client.view.kittyAttachments().snapshot();
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
    const target = try support.installTestingAttachmentTarget(client, 1);
    const capture = try client.gpa.create(CaptureType);
    capture.* = .{
        .request = .{ .target = target, .sequence = 1 },
        .png = try client.gpa.dupe(u8, "png"),
        .width = 2,
        .height = 2,
    };
    _ = try client.view.adoptAttachment(capture);
    const pane = client.model.activeTabModel().?.find(target.pane_id).?;
    pane.buffer.clear(.{});
    pane.cursor = .{
        .visible = true,
        .x = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "> [Image #1]", .style = .{} }),
        .y = 0,
    };
    var handler: InputHandler = .{ .client = client };

    try handler.key(try parseKey_module("backspace"));

    try std.testing.expectEqual(@as(u8, 0), client.view.kittyAttachments().snapshot().len);
    const pending = (try client.model.beginClipboardCapture(target)).?;
    try handler.key(try parseKey_module("enter"));
    try std.testing.expect(client.model.clipboardCapture() == null);
    const completed = try support.testingClipboardCapture(client, pending, "private png");

    try clipboard_images.complete(client, .{ .execution_id = pending.id, .result = completed });

    try std.testing.expectEqual(@as(u8, 0), client.view.kittyAttachments().snapshot().len);
    try std.testing.expect(client.clipboard_capture_resources.orphan == null);
}

test "Claude marker disappearance in a committed frame retires its paired preview" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const target = try support.installTestingAttachmentProvider(client, 1, .claude);
    const capture = try client.gpa.create(CaptureType);
    capture.* = .{
        .request = .{ .target = target, .sequence = 1, .marker_policy = .stable_number },
        .png = try client.gpa.dupe(u8, "png"),
        .width = 2,
        .height = 2,
    };
    _ = try client.view.adoptAttachment(capture);
    var pane_buffer = try BufferType.init(std.testing.allocator, 40, 3);
    defer pane_buffer.deinit();
    _ = pane_buffer.writeText(pane_buffer.area(), .{ .point = .{ .x = 0, .y = 1 }, .text = "> [Image #7]", .style = .{} });
    var payload: [16 * 1024]u8 = undefined;
    const marker_frame = try encodePaneFrame_module(&payload, .{
        .pane_id = target.pane_id,
        .frame_id = 1,
        .base_frame_id = 0,
        .cols = pane_buffer.w,
        .rows = pane_buffer.h,
        .cursor = .{ .visible = true, .x = 0, .y = 1 },
        .scroll = .{ .total_rows = pane_buffer.h, .offset = 0 },
        .spans = &.{.{ .start = 0, .cells = pane_buffer.cells }},
    });

    _ = try server_messages.handleServerMessage(client, try decodeServer_module(marker_frame));
    try std.testing.expectEqual(@as(u8, 1), client.view.kittyAttachments().snapshot().len);
    var handler: InputHandler = .{ .client = client };
    try handler.key(try parseKey_module("backspace"));
    try std.testing.expectEqual(@as(u8, 1), client.view.kittyAttachments().snapshot().len);

    pane_buffer.clear(.{});
    const empty_cursor = pane_buffer.writeText(pane_buffer.area(), .{ .point = .{ .x = 0, .y = 1 }, .text = "> ", .style = .{} });
    const empty_frame = try encodePaneFrame_module(&payload, .{
        .pane_id = target.pane_id,
        .frame_id = 2,
        .base_frame_id = 0,
        .cols = pane_buffer.w,
        .rows = pane_buffer.h,
        .cursor = .{ .visible = true, .x = empty_cursor, .y = 1 },
        .scroll = .{ .total_rows = pane_buffer.h, .offset = 0 },
        .spans = &.{.{ .start = 0, .cells = pane_buffer.cells }},
    });

    _ = try server_messages.handleServerMessage(client, try decodeServer_module(empty_frame));
    try std.testing.expectEqual(@as(u8, 0), client.view.kittyAttachments().snapshot().len);
}

const pi_test_path = "/var/folders/8x/abc/T/pi-clipboard-3f2a9c1e-7b4d-4e8f-9a0b-1c2d3e4f5a6b.png";

fn adoptPiPreview(client: *Client, target: TargetType) !void {
    const capture = try client.gpa.create(CaptureType);
    capture.* = .{
        .request = .{ .target = target, .sequence = 1, .marker_policy = .pasted_path },
        .png = try client.gpa.dupe(u8, "png"),
        .width = 2,
        .height = 2,
    };
    _ = try client.view.adoptAttachment(capture);
}

/// Commits one Pi editor frame: hidden hardware cursor, an inverse-video
/// cell right after `prompt` as Pi's own cursor.
fn commitPiFrame(client: *Client, input: PiFrame) !void {
    var pane_buffer = try BufferType.init(std.testing.allocator, 120, 3);
    defer pane_buffer.deinit();
    const cursor_x = pane_buffer.writeText(pane_buffer.area(), .{ .point = .{ .x = 0, .y = 1 }, .text = input.prompt, .style = .{} });
    pane_buffer.setCell(.{ .x = cursor_x, .y = 1 }, .{ .text = " ", .width = 1, .style = .{ .flags = .{ .inverse = true } } });
    var payload: [16 * 1024]u8 = undefined;
    const frame = try encodePaneFrame_module(&payload, .{
        .pane_id = input.target.pane_id,
        .frame_id = input.id,
        .base_frame_id = 0,
        .cols = pane_buffer.w,
        .rows = pane_buffer.h,
        .cursor = .{ .visible = false, .x = 0, .y = 0 },
        .scroll = .{ .total_rows = pane_buffer.h, .offset = 0 },
        .spans = &.{.{ .start = 0, .cells = pane_buffer.cells }},
    });

    _ = try server_messages.handleServerMessage(client, try decodeServer_module(frame));
}

test "closing a Pi preview deletes its whole pasted path from the editor" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const target = try support.installTestingAttachmentProvider(client, 1, .pi);
    try adoptPiPreview(client, target);
    try commitPiFrame(client, .{ .target = target, .prompt = "> " ++ pi_test_path, .id = 1 });
    const id = client.view.kittyAttachments().snapshot().items[0].id;
    const model = client.model.activeTabModel().?;

    _ = try view_interactions.apply(client, model, .{
        .intent = .{ .attachment_dismiss = id },
        .consumed = true,
    });

    try std.testing.expectEqual(@as(u8, 0), client.view.kittyAttachments().snapshot().len);
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
    const target = try support.installTestingAttachmentProvider(client, 1, .pi);
    try adoptPiPreview(client, target);
    try commitPiFrame(client, .{ .target = target, .prompt = "> " ++ pi_test_path, .id = 1 });
    try std.testing.expectEqual(@as(u8, 1), client.view.kittyAttachments().snapshot().len);
    var handler: InputHandler = .{ .client = client };

    try handler.key(try parseKey_module("ctrl+w"));
    try std.testing.expectEqual(@as(u8, 1), client.view.kittyAttachments().snapshot().len);
    try commitPiFrame(client, .{
        .target = target,
        .prompt = "> /var/folders/8x/abc/T/pi-clipboard-3f2a9c1e-7b4d-4e8f-9a0b-1c2d3e4f5a6b.",
        .id = 2,
    });

    try std.testing.expectEqual(@as(u8, 0), client.view.kittyAttachments().snapshot().len);
}

test "host keys use the keyboard modes received in a pane frame" {
    const lifecycle = "\x1b[97u\x1b[97;1:2u\x1b[97;1:3u\x1b[99;5u\x1b[99;1:3u";
    const cases = [_]struct { modes: InputModesType, expected: []const u8, host: []const u8 = "\x1b[13;2u\x1b[27;2;13~\r\n" }{
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
        const cells = [_]CellType{.{}};
        const snapshot = try encodePaneFrame_module(&payload, .{
            .pane_id = TestHarness.bootstrap_pane,
            .frame_id = 1,
            .base_frame_id = 0,
            .cols = 1,
            .rows = 1,
            .input_modes = case.modes,
            .scroll = .{ .total_rows = 1, .offset = 0 },
            .spans = &.{.{ .start = 0, .cells = &cells }},
        });
        _ = try server_messages.handleServerMessage(harness.client, try decodeServer_module(snapshot));
        try presentation_lifecycle.observe(harness.client);
        try harness.settleModelPresentation();
        const host_bytes = case.host;
        var chunk: Chunk = .{};
        @memcpy(chunk.bytes[0..host_bytes.len], host_bytes);
        chunk.len = @intCast(host_bytes.len);
        try std.testing.expect(!try host_inputs.handleRead(harness.client, chunk));
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
    const adoption = try support.testingConfigAdoption(1, true);
    _ = try config_reloads.apply(client, adoption);
    try std.testing.expect(!client.model.sidebarVisible());

    const lifecycle =
        "\x1b[115::115;5u" ++
        "\x1b[115::115;1:3u" ++
        "s";
    var chunk: Chunk = .{};
    @memcpy(chunk.bytes[0..lifecycle.len], lifecycle);
    chunk.len = lifecycle.len;

    try std.testing.expect(!try host_inputs.handleRead(client, chunk));

    try std.testing.expect(client.model.sidebarVisible());
    try std.testing.expect(!client.host_input.router.prefixPending());
}

test "streamed paste captures target and framing while restoring its live viewport" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const tab = &client.model.workspace.active().?.model;
    const other_pane: PaneIdType = @enumFromInt(11);
    try tab.split(.{ .existing_pane = TestHarness.bootstrap_pane, .new_pane = other_pane, .location = TestHarness.bootstrap_location, .axis = .horizontal, .area = client.view.workbench() });
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
    try support.expectNonViewportVersionEqual(version, client.model.version());
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);
    if (comptime enabled_module) {
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

    try handler.key(try parseKey_module("escape"));
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
    if (comptime enabled_module) {
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
    if (comptime enabled_module) {
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
    _ = try client.model.observeHostCapability(.{ .pointer_pixels = .supported });
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
    const hovered: PaneIdType = @enumFromInt(20);
    try model.split(.{ .existing_pane = focused, .new_pane = hovered, .location = TestHarness.bootstrap_location, .axis = .horizontal, .area = client.view.workbench() });
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

fn testingHostInput(client: *Client, bytes: []const u8) !void {
    var chunk: Chunk = .{};
    try std.testing.expect(bytes.len <= chunk.bytes.len);
    @memcpy(chunk.bytes[0..bytes.len], bytes);
    chunk.len = @intCast(bytes.len);

    try std.testing.expect(!try host_inputs.handleRead(client, chunk));
}

test "focused scroll bindings target focus rather than hover and normal input restores the viewport" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const model = client.model.activeTabModel().?;
    const focused = TestHarness.bootstrap_pane;
    const hovered: PaneIdType = @enumFromInt(20);
    try model.split(.{ .existing_pane = focused, .new_pane = hovered, .location = TestHarness.bootstrap_location, .axis = .horizontal, .area = client.view.workbench() });
    try std.testing.expect(model.focusPane(focused));
    const pane = model.find(focused).?;
    const other = model.find(hovered).?;
    pane.scroll = .{ .total_rows = @as(u32, pane.buffer.h) + 10, .offset = 10 };
    other.scroll = .{ .total_rows = @as(u32, other.buffer.h) + 10, .offset = 10 };
    const hovered_view = model.viewForPane(hovered, client.view.workbench()).?;
    var handler: InputHandler = .{ .client = client };
    try handler.mouse(.{ .x = hovered_view.content.x, .y = hovered_view.content.y, .kind = .move });
    const version = client.model.version();

    try testingHostInput(client, "\x02-");

    try std.testing.expectEqual(@as(u32, 7), pane.scroll.offset);
    try std.testing.expectEqual(@as(u32, 10), other.scroll.offset);
    try std.testing.expectEqual(focused, model.layout.focused().?);
    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expect(!client.graphics_store.paneVisible(focused));
    try std.testing.expectEqual(version.viewport + 1, client.model.version().viewport);
    try std.testing.expectEqual(@as(usize, 1), client.runtime_transport.outbox.len);
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const scrolled = try harness.nextClientMessage(&buffer);
    try std.testing.expect(scrolled == .set_pane_viewport);
    try std.testing.expectEqual(focused, scrolled.set_pane_viewport.pane_id);
    try std.testing.expectEqual(@as(u32, 7), scrolled.set_pane_viewport.offset);

    try handler.key(try parseKey_module("x"));
    try std.testing.expectEqual(@as(u32, 10), pane.scroll.offset);
    try std.testing.expect(client.graphics_store.paneVisible(focused));
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
    try testingHostInput(client, "\x02=");
    try std.testing.expectEqualDeep(bottom_version, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "held scroll suffixes pace both viewport directions without queued steps" {
    for ([_]bool{ true, false }) |up| {
        var harness: TestHarness = undefined;
        try harness.init();
        defer harness.deinit();
        try harness.bootstrap();
        const client = harness.client;
        const pane = client.model.workspace.findPane(TestHarness.bootstrap_pane).?;
        pane.scroll = .{ .total_rows = @as(u32, pane.buffer.h) + 100, .offset = 50 };
        const press = if (up) "\x02\x1b[45::45;1:1u" else "\x02\x1b[61::61;1:1u";
        const repeated = if (up) "\x1b[45::45;1:2u" else "\x1b[61::61;1:2u";
        const release = if (up) "\x1b[45::45;1:3u" else "\x1b[61::61;1:3u";
        var handler: InputHandler = .{ .client = client };
        const ms = std.time.ns_per_ms;

        _ = try client.host_input.router.feed(.{ .bytes = press, .now_ns = 0 }, &handler);
        try std.testing.expectEqual(@as(u32, if (up) 47 else 53), pane.scroll.offset);
        _ = try client.host_input.router.feed(.{ .bytes = repeated, .now_ns = 99 * ms }, &handler);
        try std.testing.expectEqual(@as(u32, if (up) 47 else 53), pane.scroll.offset);
        _ = try client.host_input.router.feed(.{ .bytes = repeated, .now_ns = 100 * ms }, &handler);
        try std.testing.expectEqual(@as(u32, if (up) 44 else 56), pane.scroll.offset);

        for (0..20) |_| {
            _ = try client.host_input.router.feed(.{ .bytes = repeated, .now_ns = 1000 * ms }, &handler);
        }

        try std.testing.expectEqual(@as(u32, if (up) 41 else 59), pane.scroll.offset);
        const version = client.model.version();
        const pending = client.runtime_transport.outbox.len;
        _ = try client.host_input.router.feed(.{ .bytes = release, .now_ns = 1001 * ms }, &handler);
        _ = try client.host_input.router.feed(.{ .bytes = repeated, .now_ns = 2000 * ms }, &handler);
        try std.testing.expectEqualDeep(version, client.model.version());
        try std.testing.expectEqual(pending, client.runtime_transport.outbox.len);
        try std.testing.expect(client.host_input.router.inputDeadline() == null);
        try std.testing.expect(client.host_input.router.bindingDeadline() == null);

        _ = try client.host_input.router.feed(.{ .bytes = press, .now_ns = 2001 * ms }, &handler);
        try std.testing.expectEqual(@as(u32, if (up) 38 else 62), pane.scroll.offset);
        pane.scroll.offset = if (up) 0 else 100;
        const at_edge = client.model.version();
        _ = try client.host_input.router.feed(.{ .bytes = repeated, .now_ns = 2101 * ms }, &handler);
        try std.testing.expectEqualDeep(at_edge, client.model.version());
    }
}

test "a held global scroll cannot move a newly focused pane or resume after returning" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const model = client.model.activeTabModel().?;
    const focused = TestHarness.bootstrap_pane;
    const second: PaneIdType = @enumFromInt(20);
    try model.split(.{ .existing_pane = focused, .new_pane = second, .location = TestHarness.bootstrap_location, .axis = .horizontal, .area = client.view.workbench() });
    try std.testing.expect(model.focusPane(focused));
    const pane = model.find(focused).?;
    const other = model.find(second).?;
    pane.scroll = .{ .total_rows = @as(u32, pane.buffer.h) + 100, .offset = 100 };
    other.scroll = .{ .total_rows = @as(u32, other.buffer.h) + 100, .offset = 100 };
    const binding = try model_module.ConfiguredBinding.parse(&.{"alt+-"}, .{ .scroll_pane = .up });
    client.host_input.replaceRouter(client.io, try host_inputs.Router.init(&.{binding}));
    var handler: InputHandler = .{ .client = client };
    const repeated = "\x1b[45::45;3:2u";

    _ = try client.host_input.router.feed(.{ .bytes = "\x1b[45::45;3:1u", .now_ns = 0 }, &handler);
    _ = try client.host_input.router.feed(.{ .bytes = repeated, .now_ns = 100 * std.time.ns_per_ms }, &handler);
    try std.testing.expectEqual(@as(u32, 94), pane.scroll.offset);
    try std.testing.expect(model.focusPane(second));
    _ = try client.host_input.router.feed(.{ .bytes = repeated, .now_ns = 200 * std.time.ns_per_ms }, &handler);
    try std.testing.expectEqual(@as(u32, 100), other.scroll.offset);
    try std.testing.expect(model.focusPane(focused));
    _ = try client.host_input.router.feed(.{ .bytes = repeated, .now_ns = 300 * std.time.ns_per_ms }, &handler);
    try std.testing.expectEqual(@as(u32, 94), pane.scroll.offset);
    try std.testing.expectEqual(@as(u32, 100), other.scroll.offset);
}

test "copy mode takes authority away from a held scroll binding" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const pane = client.model.workspace.findPane(TestHarness.bootstrap_pane).?;
    pane.scroll = .{ .total_rows = @as(u32, pane.buffer.h) + 100, .offset = 100 };
    var handler: InputHandler = .{ .client = client };

    _ = try client.host_input.router.feed(.{ .bytes = "\x02\x1b[45::45;1:1u", .now_ns = 0 }, &handler);
    _ = try client_actions.apply(client, .enter_copy_mode);
    const version = client.model.version();
    _ = try client.host_input.router.feed(.{ .bytes = "\x1b[45::45;1:2u", .now_ns = 100 * std.time.ns_per_ms }, &handler);
    try std.testing.expect(client.model.copyModeActive());
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
        _ = try client.model.observeHostCapability(.{ .cell_pixels = .{ .width = 10, .height = 20 } });
        _ = try client.model.observeHostCapability(.{ .pointer_pixels = .supported });
        const pane = client.model.workspace.findPane(TestHarness.bootstrap_pane).?;
        pane.mouse = .{ .tracking = .normal, .sgr = true, .pixels = pixels };
        pane.input_modes = .{ .alternate_screen = true, .alternate_scroll = true };
        pane.scroll = .{ .total_rows = @as(u32, pane.buffer.h) + 10, .offset = 2 };
        pane.cursor = .{ .visible = true, .x = 5, .y = 3 };
        const version = client.model.version();

        for ([_]ScrollDirectionType{ .up, .down }) |direction| {
            try testingHostInput(client, if (direction == .up) "\x02-" else "\x02=");
            try std.testing.expectEqualDeep(version, client.model.version());
            try std.testing.expectEqual(@as(u32, 2), pane.scroll.offset);
            try std.testing.expect(!client.model.copyModeActive());
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
    const pane = client.model.workspace.findPane(TestHarness.bootstrap_pane).?;
    pane.mouse = .{ .tracking = .normal, .sgr = true };
    const binding = try model_module.ConfiguredBinding.parse(&.{"alt+-"}, .{ .scroll_pane = .up });
    client.host_input.replaceRouter(client.io, try host_inputs.Router.init(&.{binding}));
    var handler: InputHandler = .{ .client = client };
    const version = client.model.version();
    const repeated = "\x1b[45::45;3:2u";

    _ = try client.host_input.router.feed(.{ .bytes = "\x1b[45::45;3:1u", .now_ns = 0 }, &handler);
    _ = try client.host_input.router.feed(.{ .bytes = repeated, .now_ns = 99 * std.time.ns_per_ms }, &handler);
    _ = try client.host_input.router.feed(.{ .bytes = repeated ++ repeated, .now_ns = 100 * std.time.ns_per_ms }, &handler);
    _ = try client.host_input.router.feed(.{ .bytes = "\x1b[45::45;1:3u" ++ repeated, .now_ns = 200 * std.time.ns_per_ms }, &handler);
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
    const model = client.model.activeTabModel().?;
    const focused = TestHarness.bootstrap_pane;
    const hovered: PaneIdType = @enumFromInt(20);
    try model.split(.{ .existing_pane = focused, .new_pane = hovered, .location = TestHarness.bootstrap_location, .axis = .horizontal, .area = client.view.workbench() });
    try std.testing.expect(model.focusPane(focused));
    const pane = model.find(focused).?;
    pane.input_modes = .{ .alternate_screen = true, .alternate_scroll = true };
    pane.scroll = .{ .total_rows = pane.buffer.h, .offset = 0 };
    const hovered_view = model.viewForPane(hovered, client.view.workbench()).?;
    var handler: InputHandler = .{ .client = client };
    try handler.mouse(.{ .x = hovered_view.content.x, .y = hovered_view.content.y, .kind = .move });
    const version = client.model.version();

    for ([_]ScrollDirectionType{ .up, .down }) |direction| {
        _ = try client_actions.apply(client, .{ .scroll_pane = direction });
        try std.testing.expectEqualDeep(version, client.model.version());
        try std.testing.expectEqual(focused, model.layout.focused().?);
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

    _ = try client_actions.apply(client, .{ .scroll_pane = .up });
    _ = try client_actions.apply(client, .{ .scroll_pane = .down });

    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "focused scroll retires copy mode before moving the restored viewport" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const pane = client.model.workspace.findPane(TestHarness.bootstrap_pane).?;
    pane.scroll = .{ .total_rows = @as(u32, pane.buffer.h) + 10, .offset = 10 };
    var handler: InputHandler = .{ .client = client };
    _ = try client_actions.apply(client, .enter_copy_mode);
    try handler.key(try parseKey_module("g"));
    try std.testing.expectEqual(@as(u32, 0), pane.scroll.offset);
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const copied = try harness.nextClientMessage(&buffer);
    try std.testing.expect(copied == .set_pane_viewport);
    try std.testing.expectEqual(@as(u32, 0), copied.set_pane_viewport.offset);

    try testingHostInput(client, "\x02-");

    try std.testing.expect(!client.model.copyModeActive());
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
    try std.testing.expect(!client.model.reportedPaneFocus().?.focus_events);

    const model = &client.model.workspace.active().?.model;
    model.find(TestHarness.bootstrap_pane).?.input_modes.focus_events = true;
    const input_events = client.telemetry.metrics.input_events;
    try active_pane_resources.synchronize(client);
    try harness.settle();

    try std.testing.expect(client.model.reportedPaneFocus().?.focus_events);
    if (comptime enabled_module) {
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

test "native agent mode action toggles the client presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();

    const client = harness.client;
    var expected_version = client.model.version();
    try std.testing.expectEqual(.normal, client.model.mode);

    for ([_]PresentationModeType{ .agent, .normal }) |expected_mode| {
        const control = try client_actions.apply(client, .toggle_agent_mode);

        expected_version.chrome +%= 1;
        try std.testing.expectEqual(ControlType.continue_routing, control);
        try std.testing.expectEqual(expected_mode, client.model.mode);
        try std.testing.expectEqualDeep(expected_version, client.model.version());
    }
}

test "configured action routing observes the client presentation mode" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();

    const client = harness.client;
    var handler: InputHandler = .{ .client = client };

    _ = try handler.action(.toggle_agent_mode);

    try std.testing.expectEqual(.agent, client.model.mode);
    const version = client.model.version();
    const sidebar_visible = client.model.sidebarVisible();

    _ = try handler.action(.toggle_sidebar);

    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(sidebar_visible, client.model.sidebarVisible());

    _ = try handler.action(.toggle_agent_mode);

    try std.testing.expectEqual(.normal, client.model.mode);
}
