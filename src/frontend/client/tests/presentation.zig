//! Client integration tests for presentation.

const TerminalClient = @import("../TerminalClient.zig");
const host = TerminalClient.of;
const TestHarness = @import("TestHarness.zig");
const presentation_lifecycle = @import("../presentation/presentation_lifecycle.zig");
const std = @import("std");
const encodeKey_module = @import("telar-client").encodeKey;
const Chunk = @import("../controllers/input/Chunk.zig");
const host_inputs = @import("../controllers/input/host_inputs.zig");
const InputHandler = @import("../resources/InputHandler.zig");
const PointerShapeType = @import("telar-core").PointerShape;
const CellType = @import("telar-core").Cell;
const encodePaneFrame_module = @import("telar-core").encodePaneFrame;
const server_messages = @import("telar-client").server_messages;
const decodeServer_module = @import("telar-core").decodeServer;
const client_actions = @import("telar-client").controllers.actions;
const runtime_transport = @import("telar-client").runtime_io;
const supportsSharedMemory_module = @import("telar-client").supportsSharedMemory;
const host_resizes = @import("../controllers/host/host_resizes.zig");
const ShmNameType = @import("telar-core").ShmName;
const ImageType = @import("telar-core").Image;
const encodeGraphicsSharedImage_module = @import("telar-core").encodeGraphicsSharedImage;
const encodeGraphicsPlacement_module = @import("telar-core").encodeGraphicsPlacement;
const enabled_module = @import("telar-core").enabled;
const OutputType = @import("../resources/Output.zig");

test "presentation folds repeated observations into one draw task" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    _ = try client.model.setDiagnostic("first revision", .{});
    try presentation_lifecycle.observe(client);

    try std.testing.expect(host(client).presenter.draw_pending);
    try std.testing.expectEqual(@as(usize, 1), host(client).presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expect(host(client).presenter.draw_pending);
    try std.testing.expectEqual(@as(usize, 1), host(client).presenter.pending_updates);

    _ = try client.model.setDiagnostic("second revision", .{});
    try presentation_lifecycle.observe(client);

    try std.testing.expect(host(client).presenter.draw_pending);
    try std.testing.expectEqual(@as(usize, 2), host(client).presenter.pending_updates);

    try harness.settleModelPresentation();

    try std.testing.expect(!host(client).presenter.draw_pending);
    try std.testing.expectEqual(@as(usize, 0), host(client).presenter.pending_updates);
    try std.testing.expectEqualDeep(client.model.version(), host(client).presenter.presentation_state.prepared.model);
}

test "an observation with pacer credit presents inline without a draw task" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    // The harness pacer schedules every frame; a real client holds burst credit.
    host(client).presenter.pacer = .{};
    const drawn_before = host(client).presenter.pacer.stats.drawn;

    _ = try client.model.setDiagnostic("inline revision", .{});
    try presentation_lifecycle.observe(client);

    try std.testing.expect(!host(client).presenter.draw_pending);
    try std.testing.expectEqual(@as(usize, 0), host(client).presenter.pending_updates);
    try std.testing.expectEqual(drawn_before + 1, host(client).presenter.pacer.stats.drawn);
    try std.testing.expectEqualDeep(client.model.version(), host(client).presenter.presentation_state.prepared.model);
}

test "host input presentation state schedules only through observation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const model_version = client.model.version();
    const input_revision = host(client).host_input.presentationVersion();
    const pending_updates = host(client).presenter.pending_updates;
    var encoded: [32]u8 = undefined;
    const prefix_bytes = try encodeKey_module(
        &encoded,
        host(client).host_input.router.prefix.?,
        .{},
    );
    var prefix: Chunk = .{};
    @memcpy(prefix.bytes[0..prefix_bytes.len], prefix_bytes);
    prefix.len = @intCast(prefix_bytes.len);

    try std.testing.expect(!try host_inputs.handleRead(client, prefix));

    try std.testing.expect(host(client).host_input.router.prefixPending());
    try std.testing.expectEqual(input_revision + 1, host(client).host_input.presentationVersion());
    try std.testing.expectEqualDeep(model_version, client.model.version());
    try std.testing.expectEqual(pending_updates, host(client).presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates + 1, host(client).presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(
        host(client).host_input.presentationVersion(),
        host(client).presenter.presentation_state.prepared.presentation_ingress.input_routing,
    );
}

test "host pointer shape follows semantic hover through paced presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    var handler: InputHandler = .{ .client = client };

    try std.testing.expectEqual(
        PointerShapeType.default,
        host(client).presenter.screen.presented_mouse_pointer.?,
    );

    try handler.mouse(.{
        .x = host(client).view.regions.top.x,
        .y = host(client).view.regions.top.y,
        .kind = .move,
    });
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(
        PointerShapeType.pointer,
        host(client).presenter.screen.presented_mouse_pointer.?,
    );

    try handler.mouse(.{
        .x = host(client).view.regions.sidebar.w - 1,
        .y = 5,
        .kind = .move,
    });
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(
        PointerShapeType.ew_resize,
        host(client).presenter.screen.presented_mouse_pointer.?,
    );

    try handler.mouse(.{
        .x = host(client).view.regions.workbench.x,
        .y = host(client).view.regions.workbench.y,
        .kind = .move,
    });
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(
        PointerShapeType.default,
        host(client).presenter.screen.presented_mouse_pointer.?,
    );

    var payload: [128]u8 = undefined;
    const cells = [_]CellType{.{}};
    for ([_]PointerShapeType{ .text, .wait, .zoom_in }, 0..) |shape, index| {
        const encoded = try encodePaneFrame_module(&payload, .{
            .pane_id = TestHarness.bootstrap_pane,
            .frame_id = index + 1,
            .base_frame_id = index,
            .cols = 1,
            .rows = 1,
            .pointer_shape = shape,
            .scroll = .{ .total_rows = 1, .offset = 0 },
            .spans = if (index == 0) &.{.{ .start = 0, .cells = &cells }} else &.{},
        });
        _ = try server_messages.handleServerMessage(client, try decodeServer_module(encoded));
        try presentation_lifecycle.observe(client);
        try harness.settleModelPresentation();
        try std.testing.expectEqual(shape, host(client).presenter.screen.presented_mouse_pointer.?);
    }

    try handler.mouse(.{ .x = host(client).view.regions.top.x, .y = host(client).view.regions.top.y, .kind = .move });
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(PointerShapeType.pointer, host(client).presenter.screen.presented_mouse_pointer.?);

    _ = try client_actions.apply(client, .enter_copy_mode);
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    try handler.mouse(.{ .x = host(client).view.regions.workbench.x, .y = host(client).view.regions.workbench.y, .kind = .move });
    try handler.key(.plain(.escape));
    try std.testing.expect(!client.model.copyModeActive());
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(PointerShapeType.default, host(client).presenter.screen.presented_mouse_pointer.?);

    try handler.mouse(.{ .x = host(client).view.regions.workbench.x, .y = host(client).view.regions.workbench.y, .kind = .move });
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(PointerShapeType.zoom_in, host(client).presenter.screen.presented_mouse_pointer.?);
}

test "presentation flushes an explicit empty model before bootstrap" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;

    try std.testing.expect(client.model.activeTabModel() == null);
    _ = try client.model.setDiagnostic("pre-bootstrap revision", .{});
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();

    try std.testing.expectEqualDeep(client.model.version(), host(client).presenter.presentation_state.prepared.model);
    for (host(client).presenter.screen.front.cells) |cell| {
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

    host(client).presenter.draw_pending = true;
    host(client).presenter.media_tick_pending = true;
    try presentation_lifecycle.handleMediaTick(client, {});

    try std.testing.expect(!host(client).presenter.media_tick_pending);
    try std.testing.expect(host(client).presenter.media_after_draw);

    host(client).presenter.draw_pending = false;
    try host(client).presenter.requestMedia();

    try std.testing.expect(host(client).presenter.media_tick_pending);
    try std.testing.expect(!host(client).presenter.media_after_draw);
    // The deferred pass was armed for now, not a pacer interval later.
    while (true) {
        switch (try host(client).select.await()) {
            .media_tick => |result| {
                try presentation_lifecycle.handleMediaTick(client, result);
                break;
            },
            .sent => |result| try runtime_transport.handleSent(client, result),
            else => return error.UnexpectedEvent,
        }
    }
    try std.testing.expect(!host(client).presenter.media_tick_pending);
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
    if (comptime !supportsSharedMemory_module()) {
        return error.SkipZigTest;
    }

    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    _ = try host_resizes.apply(client, .{ .cols = 80, .rows = 24, .width_px = 800, .height_px = 480 });
    _ = try client.model.observeHostCapability(.{ .images = .supported });
    host(client).graphics_store.shared_memory = true;
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();

    var capture: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer capture.deinit();
    host(client).writer = &capture.writer;

    var name_buffer: [64]u8 = undefined;
    const name = try ShmNameType.init(try std.fmt.bufPrint(
        &name_buffer,
        "/tlrtest-frame-{d}",
        .{std.c.getpid()},
    ));
    _ = std.c.shm_unlink(name.sliceZ());
    try createSharedObject(name.sliceZ(), &.{ 1, 2, 3, 255 });
    defer _ = std.c.shm_unlink(name.sliceZ());

    var payload: [256]u8 = undefined;
    const image: ImageType = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    };
    const shared = try encodeGraphicsSharedImage_module(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .revision = 1,
        .image = image,
        .name = name,
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(shared));
    const placement = try encodeGraphicsPlacement_module(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .revision = 1,
        .placement = .{ .key = image.key, .virtual_id = 1, .placement_id = 1, .x = 0, .y = 0 },
    });
    _ = try server_messages.handleServerMessage(client, try decodeServer_module(placement));
    try presentation_lifecycle.observe(client);
    try std.testing.expect(host(client).presenter.draw_pending);
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
    if (comptime enabled_module) {
        try std.testing.expectEqual(@as(u64, 1), client.telemetry.metrics.pane_shared_images);
    }

    // The transmit asked the host for a reply; its OK reaches the store.
    try std.testing.expect(std.mem.indexOf(u8, host_bytes[transmit..place], "q=0;") != null);
    var images = host(client).graphics_store.images.iterator();
    const entry = images.next() orelse return error.ImageMissing;
    try std.testing.expect(!entry.value_ptr.delivery.host_acked);
    var handler: InputHandler = .{ .client = client };
    try handler.terminalResponse(.{ .kitty_graphics = .{
        .image_id = entry.value_ptr.delivery.external_id,
        .supported = true,
    } });
    try std.testing.expect(entry.value_ptr.delivery.host_acked);
}

test "presentation worker failures release their scheduling tokens" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;

    host(client).presenter.draw_pending = true;
    try std.testing.expectError(
        error.DrawWorkerFailed,
        presentation_lifecycle.handleDraw(client, error.DrawWorkerFailed),
    );
    try std.testing.expect(!host(client).presenter.draw_pending);

    host(client).presenter.media_tick_pending = true;
    try std.testing.expectError(
        error.MediaWorkerFailed,
        presentation_lifecycle.handleMediaTick(client, error.MediaWorkerFailed),
    );
    try std.testing.expect(!host(client).presenter.media_tick_pending);
}

test "the TUI write boundary alone completes the shared presentation token" {
    const Output = OutputType;
    for ([_]bool{ false, true }) |fail| {
        var harness: TestHarness = undefined;
        try harness.init();
        defer harness.deinit();
        try harness.bootstrap();
        try harness.settleModelPresentation();
        const client = harness.client;
        const pane = client.model.workspace.findPane(TestHarness.bootstrap_pane).?;
        pane.pending_frame_id = 7;
        const before = host(client).presenter.presentation_state.delivered;
        const token = try host(client).presenter.presentation_state.begin(.{
            .observation = host(client).presenter.presentation_state.observed,
            .commit = client.model.activeTabModelConst().?.presentationCommit(),
        });
        host(client).output = try Output.init(std.testing.allocator, host(client).writer);
        const output = &host(client).output.?;
        output.delivery = token;
        try output.writer.writeAll("frame");
        const work = output.begin().?;
        try std.testing.expectEqual(@as(u64, 7), pane.pending_frame_id);
        try std.testing.expectEqualDeep(before, host(client).presenter.presentation_state.delivered);
        if (fail) {
            try std.testing.expectError(error.WriteFailed, presentation_lifecycle.handleWritten(client, error.WriteFailed));
            try std.testing.expectEqual(@as(u64, 7), pane.pending_frame_id);
            try std.testing.expect(host(client).presenter.presentation_state.preparation_invalid);
        } else {
            try Output.write(work);
            try presentation_lifecycle.handleWritten(client, {});
            try std.testing.expectEqual(@as(u64, 0), pane.pending_frame_id);
            var wire: [1024]u8 = undefined;
            try std.testing.expectEqual(@as(u64, 7), (try harness.nextClientMessage(&wire)).frame_ack.frame_id);
        }
        try std.testing.expect(host(client).presenter.presentation_state.active == null);
        try std.testing.expect(!output.pending);
    }
}
