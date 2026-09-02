//! Client integration tests for presentation.

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

test "presentation folds repeated observations into one draw task" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    _ = try client.model.setDiagnostic("first revision", .{});
    try presentation_lifecycle.observe(client);

    try std.testing.expect(client.presenter.draw_pending);
    try std.testing.expectEqual(@as(usize, 1), client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expect(client.presenter.draw_pending);
    try std.testing.expectEqual(@as(usize, 1), client.presenter.pending_updates);

    _ = try client.model.setDiagnostic("second revision", .{});
    try presentation_lifecycle.observe(client);

    try std.testing.expect(client.presenter.draw_pending);
    try std.testing.expectEqual(@as(usize, 2), client.presenter.pending_updates);

    try harness.settleModelPresentation();

    try std.testing.expect(!client.presenter.draw_pending);
    try std.testing.expectEqual(@as(usize, 0), client.presenter.pending_updates);
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
}

test "host input presentation state schedules only through observation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const model_version = client.model.version();
    const input_revision = client.host_input.presentationVersion();
    const pending_updates = client.presenter.pending_updates;
    var encoded: [32]u8 = undefined;
    const prefix_bytes = try input_capability.host.encodeKey(
        &encoded,
        client.host_input.router.prefix.?,
        .{},
    );
    var prefix: InputChunk = .{};
    @memcpy(prefix.bytes[0..prefix_bytes.len], prefix_bytes);
    prefix.len = @intCast(prefix_bytes.len);

    try std.testing.expect(!try host_inputs.handleRead(client, prefix));

    try std.testing.expect(client.host_input.router.prefixPending());
    try std.testing.expectEqual(input_revision + 1, client.host_input.presentationVersion());
    try std.testing.expectEqualDeep(model_version, client.model.version());
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(
        client.host_input.presentationVersion(),
        client.presenter.presented_presentation_ingress.input_routing,
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
        presentation.pointer.Shape.default,
        client.presenter.screen.presented_mouse_pointer.?,
    );

    try handler.mouse(.{
        .x = client.view.regions.top.x,
        .y = client.view.regions.top.y,
        .kind = .move,
    });
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(
        presentation.pointer.Shape.pointer,
        client.presenter.screen.presented_mouse_pointer.?,
    );

    try handler.mouse(.{
        .x = client.view.regions.sidebar.w - 1,
        .y = 5,
        .kind = .move,
    });
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(
        presentation.pointer.Shape.horizontal_resize,
        client.presenter.screen.presented_mouse_pointer.?,
    );

    try handler.mouse(.{
        .x = client.view.regions.workbench.x,
        .y = client.view.regions.workbench.y,
        .kind = .move,
    });
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(
        presentation.pointer.Shape.default,
        client.presenter.screen.presented_mouse_pointer.?,
    );
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

    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
    for (client.presenter.screen.front.cells) |cell| {
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

    client.presenter.draw_pending = true;
    client.presenter.media_tick_pending = true;
    try presentation_lifecycle.handleMediaTick(client, {});

    try std.testing.expect(!client.presenter.media_tick_pending);
    try std.testing.expect(client.presenter.media_after_draw);

    client.presenter.draw_pending = false;
    try client.presenter.requestMedia();

    try std.testing.expect(client.presenter.media_tick_pending);
    try std.testing.expect(!client.presenter.media_after_draw);
    // The deferred pass was armed for now, not a pacer interval later.
    while (true) {
        switch (try client.select.await()) {
            .media_tick => |result| {
                try presentation_lifecycle.handleMediaTick(client, result);
                break;
            },
            .sent => |result| try runtime_transport.handleSent(client, result),
            else => return error.UnexpectedEvent,
        }
    }
    try std.testing.expect(!client.presenter.media_tick_pending);
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
    if (comptime !kitty.supportsSharedMemory()) return error.SkipZigTest;

    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    _ = try host_resizes.apply(client, .{ .cols = 80, .rows = 24, .width_px = 800, .height_px = 480 });
    _ = try client.model.observeHostCapability(.{ .kitty_graphics = .supported });
    client.graphics_store.shared_memory = true;
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();

    var capture: Io.Writer.Allocating = .init(std.testing.allocator);
    defer capture.deinit();
    client.writer = &capture.writer;

    var name_buffer: [64]u8 = undefined;
    const name = try core.graphics.ShmName.init(try std.fmt.bufPrint(
        &name_buffer,
        "/tlrtest-frame-{d}",
        .{std.c.getpid()},
    ));
    _ = std.c.shm_unlink(name.sliceZ());
    try createSharedObject(name.sliceZ(), &.{ 1, 2, 3, 255 });
    defer _ = std.c.shm_unlink(name.sliceZ());

    var payload: [256]u8 = undefined;
    const image: core.graphics.Image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .byte_len = 4,
    };
    const shared = try schema.encodeGraphicsSharedImage(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .revision = 1,
        .image = image,
        .name = name,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(shared));
    const placement = try schema.encodeGraphicsPlacement(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .revision = 1,
        .placement = .{ .key = image.key, .virtual_id = 1, .placement_id = 1, .x = 0, .y = 0 },
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(placement));
    try presentation_lifecycle.observe(client);
    try std.testing.expect(client.presenter.draw_pending);
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
    if (comptime core.diagnostics.enabled) {
        try std.testing.expectEqual(@as(u64, 1), client.telemetry.metrics.pane_shared_images);
    }

    // The transmit asked the host for a reply; its OK reaches the store.
    try std.testing.expect(std.mem.indexOf(u8, host_bytes[transmit..place], "q=0;") != null);
    var images = client.graphics_store.images.iterator();
    const entry = images.next() orelse return error.ImageMissing;
    try std.testing.expect(!entry.value_ptr.host_acked);
    var handler: InputHandler = .{ .client = client };
    try handler.terminalResponse(.{ .kitty_graphics = .{
        .image_id = entry.value_ptr.external_id,
        .supported = true,
    } });
    try std.testing.expect(entry.value_ptr.host_acked);
}

test "presentation worker failures release their scheduling tokens" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;

    client.presenter.draw_pending = true;
    try std.testing.expectError(
        error.DrawWorkerFailed,
        presentation_lifecycle.handleDraw(client, error.DrawWorkerFailed),
    );
    try std.testing.expect(!client.presenter.draw_pending);

    client.presenter.media_tick_pending = true;
    try std.testing.expectError(
        error.MediaWorkerFailed,
        presentation_lifecycle.handleMediaTick(client, error.MediaWorkerFailed),
    );
    try std.testing.expect(!client.presenter.media_tick_pending);
}
