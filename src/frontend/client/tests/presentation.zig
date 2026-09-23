//! Client integration tests for presentation.

const client_module = @import("telar-client");
const core = @import("telar-core");
const data = @import("model");
const TerminalClient = @import("../TerminalClient.zig");
const TestHarness = @import("TestHarness.zig");
const presentation_lifecycle = @import("../presentation/presentation_lifecycle.zig");
const std = @import("std");
const Chunk = @import("../controllers/input/Chunk.zig");
const host_inputs = @import("../controllers/input/host_inputs.zig");
const host_resizes = @import("../controllers/host/host_resizes.zig");
const OutputType = @import("../resources/Output.zig");

test "presentation folds repeated observations into one draw task" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;

    _ = try client.model.setDiagnostic("first revision", .{});
    try presentation_lifecycle.observe(terminal);

    try std.testing.expect(terminal.presenter.draw_pending);
    try std.testing.expectEqual(@as(usize, 1), terminal.presenter.pending_updates);

    try presentation_lifecycle.observe(terminal);

    try std.testing.expect(terminal.presenter.draw_pending);
    try std.testing.expectEqual(@as(usize, 1), terminal.presenter.pending_updates);

    _ = try client.model.setDiagnostic("second revision", .{});
    try presentation_lifecycle.observe(terminal);

    try std.testing.expect(terminal.presenter.draw_pending);
    try std.testing.expectEqual(@as(usize, 2), terminal.presenter.pending_updates);

    try harness.settleModelPresentation();

    try std.testing.expect(!terminal.presenter.draw_pending);
    try std.testing.expectEqual(@as(usize, 0), terminal.presenter.pending_updates);
    try std.testing.expectEqualDeep(client.model.version(), terminal.presenter.presentation_state.prepared.model);
}

test "an observation with pacer credit presents inline without a draw task" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    // The harness pacer schedules every frame; a real client holds burst credit.
    terminal.presenter.pacer = .{};
    const drawn_before = terminal.presenter.pacer.stats.drawn;

    _ = try client.model.setDiagnostic("inline revision", .{});
    try presentation_lifecycle.observe(terminal);

    try std.testing.expect(!terminal.presenter.draw_pending);
    try std.testing.expectEqual(@as(usize, 0), terminal.presenter.pending_updates);
    try std.testing.expectEqual(drawn_before + 1, terminal.presenter.pacer.stats.drawn);
    try std.testing.expectEqualDeep(client.model.version(), terminal.presenter.presentation_state.prepared.model);
}

test "host input presentation state schedules only through observation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    const model_version = client.model.version();
    const input_revision = terminal.host_input.presentationVersion();
    const pending_updates = terminal.presenter.pending_updates;
    var encoded: [32]u8 = undefined;
    const prefix_bytes = try client_module.encodeKey(
        &encoded,
        terminal.host_input.router.prefix.?,
        .{},
    );
    var prefix: Chunk = .{};
    @memcpy(prefix.bytes[0..prefix_bytes.len], prefix_bytes);
    prefix.len = @intCast(prefix_bytes.len);

    try std.testing.expect(!try host_inputs.handleRead(terminal, prefix));

    try std.testing.expect(terminal.host_input.router.prefixPending());
    try std.testing.expectEqual(input_revision + 1, terminal.host_input.presentationVersion());
    try std.testing.expectEqualDeep(model_version, client.model.version());
    try std.testing.expectEqual(pending_updates, terminal.presenter.pending_updates);

    try presentation_lifecycle.observe(terminal);

    try std.testing.expectEqual(pending_updates + 1, terminal.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(
        terminal.host_input.presentationVersion(),
        terminal.presenter.presentation_state.prepared.presentation_ingress.input_routing,
    );
}

test "host pointer shape follows semantic hover through paced presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;

    try std.testing.expectEqual(
        core.PointerShape.default,
        terminal.presenter.screen.presented_mouse_pointer.?,
    );

    try host_inputs.mouse(terminal, .{
        .x = terminal.view.regions.top.x,
        .y = terminal.view.regions.top.y,
        .kind = .move,
    });
    try presentation_lifecycle.observe(terminal);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(
        core.PointerShape.pointer,
        terminal.presenter.screen.presented_mouse_pointer.?,
    );

    try host_inputs.mouse(terminal, .{
        .x = terminal.view.regions.sidebar.w - 1,
        .y = 5,
        .kind = .move,
    });
    try presentation_lifecycle.observe(terminal);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(
        core.PointerShape.ew_resize,
        terminal.presenter.screen.presented_mouse_pointer.?,
    );

    try host_inputs.mouse(terminal, .{
        .x = terminal.view.regions.workbench.x,
        .y = terminal.view.regions.workbench.y,
        .kind = .move,
    });
    try presentation_lifecycle.observe(terminal);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(
        core.PointerShape.default,
        terminal.presenter.screen.presented_mouse_pointer.?,
    );

    var payload: [128]u8 = undefined;
    const cells = [_]core.Cell{.{}};
    for ([_]core.PointerShape{ .text, .wait, .zoom_in }, 0..) |shape, index| {
        const encoded = try core.encodePaneFrame(&payload, .{
            .pane_id = TestHarness.bootstrap_pane,
            .frame_id = index + 1,
            .base_frame_id = index,
            .cols = 1,
            .rows = 1,
            .pointer_shape = shape,
            .scroll = .{ .total_rows = 1, .offset = 0 },
            .spans = if (index == 0) &.{.{ .start = 0, .cells = &cells }} else &.{},
        });
        _ = try client.handleServerMessage(try core.decodeServer(encoded));
        try presentation_lifecycle.observe(terminal);
        try harness.settleModelPresentation();
        try std.testing.expectEqual(shape, terminal.presenter.screen.presented_mouse_pointer.?);
    }

    try host_inputs.mouse(terminal, .{ .x = terminal.view.regions.top.x, .y = terminal.view.regions.top.y, .kind = .move });
    try presentation_lifecycle.observe(terminal);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(core.PointerShape.pointer, terminal.presenter.screen.presented_mouse_pointer.?);

    _ = try client.executeAction(.enter_copy_mode, .effect);
    try presentation_lifecycle.observe(terminal);
    try harness.settleModelPresentation();
    try host_inputs.mouse(terminal, .{ .x = terminal.view.regions.workbench.x, .y = terminal.view.regions.workbench.y, .kind = .move });
    try host_inputs.key(terminal, .plain(.escape));
    try std.testing.expect(!client.model.copyModeActive());
    try presentation_lifecycle.observe(terminal);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(core.PointerShape.default, terminal.presenter.screen.presented_mouse_pointer.?);

    try host_inputs.mouse(terminal, .{ .x = terminal.view.regions.workbench.x, .y = terminal.view.regions.workbench.y, .kind = .move });
    try presentation_lifecycle.observe(terminal);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(core.PointerShape.zoom_in, terminal.presenter.screen.presented_mouse_pointer.?);
}

test "presentation flushes an explicit empty model before bootstrap" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const terminal = harness.terminal;

    try std.testing.expect(client.model.tabs.activeSlot() == null);
    _ = try client.model.setDiagnostic("pre-bootstrap revision", .{});
    try presentation_lifecycle.observe(terminal);
    try harness.settleModelPresentation();

    try std.testing.expectEqualDeep(client.model.version(), terminal.presenter.presentation_state.prepared.model);
    for (terminal.presenter.screen.front.cells) |cell| {
        try std.testing.expectEqualStrings(" ", cell.text());
        try std.testing.expectEqual(@as(u8, 1), cell.width);
    }
}

test "a media tick that yields to a pending draw runs at that draw's completion" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;

    terminal.presenter.draw_pending = true;
    terminal.presenter.media_tick_pending = true;
    try presentation_lifecycle.handleMediaTick(terminal, {});

    try std.testing.expect(!terminal.presenter.media_tick_pending);
    try std.testing.expect(terminal.presenter.media_after_draw);

    terminal.presenter.draw_pending = false;
    try terminal.presenter.requestMedia();

    try std.testing.expect(terminal.presenter.media_tick_pending);
    try std.testing.expect(!terminal.presenter.media_after_draw);
    // The deferred pass was armed for now, not a pacer interval later.
    while (true) {
        switch (try terminal.inbox.receive()) {
            .media_tick => |result| {
                try presentation_lifecycle.handleMediaTick(terminal, result);
                break;
            },
            .client => |message| switch (message) {
                .sent => |result| try client.completeRuntimeSend(result),
                else => return error.UnexpectedEvent,
            },
            else => return error.UnexpectedEvent,
        }
    }
    try std.testing.expect(!terminal.presenter.media_tick_pending);
}

fn createSharedObject(name: [:0]const u8, pixels: []const u8) !void {
    const fd = std.c.shm_open(
        name,
        @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true })),
        @as(u16, 0o600),
    );
    try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(fd));
    defer _ = std.c.close(fd);
    try std.testing.expectEqual(@as(c_int, 0), std.c.ftruncate(fd, @intCast(pixels.len)));
    const map = try std.posix.mmap(
        null,
        pixels.len,
        .{ .READ = true, .WRITE = true },
        std.c.MAP{ .TYPE = .SHARED },
        fd,
        0,
    );
    defer std.posix.munmap(map);
    @memcpy(map[0..pixels.len], pixels);
}

test "shared pane graphics reach the host inside the cell frame" {
    if (comptime !client_module.supportsSharedMemory()) {
        return error.SkipZigTest;
    }

    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const terminal = harness.terminal;
    _ = try host_resizes.apply(terminal, .{ .cols = 80, .rows = 24, .width_px = 800, .height_px = 480 });
    _ = try client.model.observeHostCapability(.{ .images = .supported });
    terminal.graphics_store.shared_memory = true;
    try presentation_lifecycle.observe(terminal);
    try harness.settleModelPresentation();

    var capture: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer capture.deinit();
    terminal.writer = &capture.writer;

    var name_buffer: [64]u8 = undefined;
    const name = try core.ShmName.init(try std.fmt.bufPrint(
        &name_buffer,
        "/tlrtest-frame-{d}",
        .{std.c.getpid()},
    ));
    _ = std.c.shm_unlink(name.sliceZ());
    try createSharedObject(name.sliceZ(), &.{ 1, 2, 3, 255 });
    defer _ = std.c.shm_unlink(name.sliceZ());

    var payload: [256]u8 = undefined;
    const image: core.Image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    };
    const shared = try core.encodeGraphicsSharedImage(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .revision = 1,
        .image = image,
        .name = name,
    });
    _ = try client.handleServerMessage(try core.decodeServer(shared));
    const placement = try core.encodeGraphicsPlacement(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .revision = 1,
        .placement = .{ .key = image.key, .virtual_id = 1, .placement_id = 1, .x = 0, .y = 0 },
    });
    _ = try client.handleServerMessage(try core.decodeServer(placement));
    try presentation_lifecycle.observe(terminal);
    try std.testing.expect(terminal.presenter.draw_pending);
    try harness.settleModelPresentation();

    const host_bytes = capture.written();
    const transmit = std.mem.indexOf(u8, host_bytes, "t=s") orelse return error.SharedNameNotSent;
    const place = std.mem.indexOf(u8, host_bytes, "a=p,") orelse return error.PlacementNotSent;
    try std.testing.expect(transmit < place);
    // Both escapes sit inside the synchronized update the cells opened.
    const begin = std.mem.lastIndexOf(u8, host_bytes[0..transmit], "\x1b[?2026h") orelse
        return error.FrameNotSynchronized;
    try std.testing.expect(std.mem.indexOf(u8, host_bytes[begin..place], "\x1b[?2026l") == null);
    try std.testing.expect(std.mem.indexOf(u8, host_bytes[place..], "\x1b[?2026l") != null);
    if (comptime core.enabled) {
        try std.testing.expectEqual(@as(u64, 1), client.telemetry.metrics.pane_shared_images);
    }

    // The transmit asked the host for a reply; its OK reaches the store.
    try std.testing.expect(std.mem.indexOf(u8, host_bytes[transmit..place], "q=0;") != null);
    var images = terminal.graphics_store.images.iterator();
    const entry = images.next() orelse return error.ImageMissing;
    try std.testing.expect(!entry.value_ptr.delivery.host_acked);
    try host_inputs.terminalResponse(terminal, .{ .kitty_graphics = .{
        .image_id = entry.value_ptr.delivery.external_id,
        .supported = true,
    } });
    try std.testing.expect(entry.value_ptr.delivery.host_acked);
}

test "presentation worker failures release their scheduling tokens" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const terminal = harness.terminal;

    terminal.presenter.draw_pending = true;
    try std.testing.expectError(
        error.DrawWorkerFailed,
        presentation_lifecycle.handleDraw(terminal, error.DrawWorkerFailed),
    );
    try std.testing.expect(!terminal.presenter.draw_pending);

    terminal.presenter.media_tick_pending = true;
    try std.testing.expectError(
        error.MediaWorkerFailed,
        presentation_lifecycle.handleMediaTick(terminal, error.MediaWorkerFailed),
    );
    try std.testing.expect(!terminal.presenter.media_tick_pending);
}

test "TUI frame ACKs advance while a sealed host write retains its presentation token" {
    const Output = OutputType;
    for ([_]bool{ false, true }) |fail| {
        var harness: TestHarness = undefined;
        try harness.init();
        defer harness.deinit();
        try harness.bootstrap();
        try harness.settleModelPresentation();
        const client = harness.client;
        const terminal = harness.terminal;
        const pane = client.model.panes.find(TestHarness.bootstrap_pane).?;
        try receiveCellFrame(&harness, 1);
        var wire: [1024]u8 = undefined;
        try std.testing.expectEqual(@as(u64, 1), (try harness.nextClientMessage(&wire)).frame_ack.frame_id);
        try harness.settle();
        const before = terminal.presenter.presentation_state.delivered;
        const token = try terminal.presenter.presentation_state.begin(.{
            .observation = terminal.presenter.presentation_state.observed,
            .commit = data.presentation_delivery.capture(&client.model, client.model.tabs.active),
        });
        terminal.output = try Output.init(std.testing.allocator, terminal.writer);
        const output = &terminal.output.?;
        output.delivery = token;
        try output.writer.writeAll("frame");
        const work = output.begin().?;
        try std.testing.expectEqual(@as(u64, 1), pane.pending_frame_id);
        try std.testing.expectEqualDeep(before, terminal.presenter.presentation_state.delivered);
        try receiveCellFrame(&harness, 2);
        try std.testing.expectEqual(@as(u64, 2), (try harness.nextClientMessage(&wire)).frame_ack.frame_id);
        try harness.settle();
        try std.testing.expect(output.pending);
        try std.testing.expectEqualStrings("frame", work.bytes);
        try std.testing.expectEqualStrings("B", pane.buffer.cells[0].text());
        if (fail) {
            try std.testing.expectError(error.WriteFailed, presentation_lifecycle.handleWritten(terminal, error.WriteFailed));
            try std.testing.expect(terminal.presenter.presentation_state.preparation_invalid);
        } else {
            try Output.write(work);
            try presentation_lifecycle.handleWritten(terminal, {});
        }

        try std.testing.expectEqual(@as(u64, 2), pane.pending_frame_id);
        try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
        try std.testing.expect(terminal.presenter.presentation_state.active == null);
        try std.testing.expect(!output.pending);
    }
}

fn receiveCellFrame(harness: *TestHarness, frame_id: u64) !void {
    var cells: [4]core.Cell = @splat(.{});
    cells[0].bytes[0] = if (frame_id == 1) 'A' else 'B';
    var wire: [1024]u8 = undefined;
    const payload = try core.encodePaneFrame(&wire, .{
        .pane_id = TestHarness.bootstrap_pane,
        .frame_id = frame_id,
        .base_frame_id = frame_id - 1,
        .cols = 2,
        .rows = 2,
        .scroll = .{ .total_rows = 2, .offset = 0 },
        .spans = &.{.{ .start = 0, .cells = if (frame_id == 1) &cells else cells[0..1] }},
    });
    _ = try harness.client.handleServerMessage(try core.decodeServer(payload));
    @memset(&wire, 0xff);
}
