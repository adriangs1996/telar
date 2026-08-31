//! Substituted-platform tests for the Client: a real Client over a
//! socketpair standing in for the runtime socket, a pipe for the tty's
//! read handle, and a discarding writer for the host terminal.

const std = @import("std");
const core = @import("telar-core");
const agents = @import("../agents/root.zig");
const attachments = @import("../attachments/root.zig");
const graphics = @import("../graphics/root.zig");
const input_capability = @import("../input/root.zig");
const lua_config = @import("../config/root.zig");
const notifications = @import("../notifications/root.zig");
const platform = @import("../platform/root.zig");
const plugin_broker = @import("../plugins/root.zig");
const presentation = @import("../presentation/root.zig");
const sound_capability = @import("../sound/root.zig");
const workspace_capability = @import("../workspace/root.zig");
const keybind = input_capability.keybind;
const kitty = graphics.kitty;

const Io = std.Io;
const File = Io.File;
const schema = core.schema;
const term = presentation.screen;

const Client = @import("client.zig");
const InputHandler = @import("input_handler.zig");
const client_actions = @import("actions.zig");
const agent_sounds = @import("agent_sounds.zig");
const attachment_targets = @import("attachment_targets.zig");
const client_application = @import("application/root.zig");
const client_outbox = @import("outbox.zig");
const client_model = @import("model.zig");
const client_telemetry = @import("telemetry.zig");
const config_reload_worker = @import("config_reload.zig");
const config_reloads = @import("config_reloads.zig");
const host_inputs = @import("host_inputs.zig");
const host_resizes = @import("host_resizes.zig");
const name_prompts = @import("name_prompts.zig");
const notification_flow = @import("notifications.zig");
const pane_clipboards = @import("pane_clipboards.zig");
const pane_closures = @import("pane_closures.zig");
const pane_focus = @import("pane_focus.zig");
const pane_geometry = @import("pane_geometry.zig");
const pane_openings = @import("pane_openings.zig");
const presentation_lifecycle = @import("presentation_lifecycle.zig");
const plugin_actions = @import("plugin_actions.zig");
const request_lifecycle = @import("request_lifecycle.zig");
const resync_requirements = @import("resync_requirements.zig");
const runtime_transport = @import("runtime_transport.zig");
const server_messages = @import("server_messages.zig");
const sidebar_animations = @import("sidebar_animations.zig");
const sidebar_projection = @import("sidebar_projection.zig");
const tab_attachments = @import("tab_attachments.zig");
const tab_closures = @import("tab_closures.zig");
const tab_creations = @import("tab_creations.zig");
const tab_moves = @import("tab_moves.zig");
const tab_renames = @import("tab_renames.zig");
const tab_snapshots = @import("tab_snapshots.zig");
const workspace_snapshots = @import("workspace_snapshots.zig");
const InputChunk = Client.InputChunk;
const initial_request_id = request_lifecycle.initial_request_id;

fn reportedPaneId(client: *const Client) ?schema.PaneId {
    const reported = client.model.reportedPaneFocus() orelse return null;

    return reported.pane_id;
}

fn expectNonPromptVersionEqual(expected: client_model.Version, actual: client_model.Version) !void {
    try std.testing.expectEqual(expected.workspace, actual.workspace);
    try std.testing.expectEqual(expected.configuration, actual.configuration);
    try std.testing.expectEqual(expected.diagnostic, actual.diagnostic);
    try std.testing.expectEqual(expected.host, actual.host);
    try std.testing.expectEqual(expected.host_capabilities, actual.host_capabilities);
    try std.testing.expectEqual(expected.workspace_list, actual.workspace_list);
    try std.testing.expectEqual(expected.agents, actual.agents);
    try std.testing.expectEqual(expected.sidebar_animation, actual.sidebar_animation);
    try std.testing.expectEqual(expected.proxy_status, actual.proxy_status);
    try std.testing.expectEqual(expected.system_metrics, actual.system_metrics);
    try std.testing.expectEqual(expected.notifications, actual.notifications);
    try std.testing.expectEqual(expected.tabs, actual.tabs);
    try std.testing.expectEqual(expected.active_tab, actual.active_tab);
    try std.testing.expectEqual(expected.panes, actual.panes);
    try std.testing.expectEqual(expected.frame, actual.frame);
    try std.testing.expectEqual(expected.pane_metadata, actual.pane_metadata);
    try std.testing.expectEqual(expected.pane_foreground, actual.pane_foreground);
    try std.testing.expectEqual(expected.pane_graphics, actual.pane_graphics);
    try std.testing.expectEqual(expected.chrome, actual.chrome);
    try std.testing.expectEqual(expected.copy, actual.copy);
    try std.testing.expectEqual(expected.viewport, actual.viewport);
}

fn expectNonCopyVersionEqual(expected: client_model.Version, actual: client_model.Version) !void {
    try std.testing.expectEqual(expected.workspace, actual.workspace);
    try std.testing.expectEqual(expected.configuration, actual.configuration);
    try std.testing.expectEqual(expected.diagnostic, actual.diagnostic);
    try std.testing.expectEqual(expected.host, actual.host);
    try std.testing.expectEqual(expected.host_capabilities, actual.host_capabilities);
    try std.testing.expectEqual(expected.workspace_list, actual.workspace_list);
    try std.testing.expectEqual(expected.agents, actual.agents);
    try std.testing.expectEqual(expected.sidebar_animation, actual.sidebar_animation);
    try std.testing.expectEqual(expected.proxy_status, actual.proxy_status);
    try std.testing.expectEqual(expected.system_metrics, actual.system_metrics);
    try std.testing.expectEqual(expected.notifications, actual.notifications);
    try std.testing.expectEqual(expected.tabs, actual.tabs);
    try std.testing.expectEqual(expected.active_tab, actual.active_tab);
    try std.testing.expectEqual(expected.panes, actual.panes);
    try std.testing.expectEqual(expected.frame, actual.frame);
    try std.testing.expectEqual(expected.pane_metadata, actual.pane_metadata);
    try std.testing.expectEqual(expected.pane_foreground, actual.pane_foreground);
    try std.testing.expectEqual(expected.pane_graphics, actual.pane_graphics);
    try std.testing.expectEqual(expected.chrome, actual.chrome);
    try std.testing.expectEqual(expected.prompt, actual.prompt);
    try std.testing.expectEqual(expected.viewport, actual.viewport);
}

fn expectNonCopyOrViewportVersionEqual(expected: client_model.Version, actual: client_model.Version) !void {
    try std.testing.expectEqual(expected.workspace, actual.workspace);
    try std.testing.expectEqual(expected.configuration, actual.configuration);
    try std.testing.expectEqual(expected.diagnostic, actual.diagnostic);
    try std.testing.expectEqual(expected.host, actual.host);
    try std.testing.expectEqual(expected.host_capabilities, actual.host_capabilities);
    try std.testing.expectEqual(expected.workspace_list, actual.workspace_list);
    try std.testing.expectEqual(expected.agents, actual.agents);
    try std.testing.expectEqual(expected.sidebar_animation, actual.sidebar_animation);
    try std.testing.expectEqual(expected.proxy_status, actual.proxy_status);
    try std.testing.expectEqual(expected.system_metrics, actual.system_metrics);
    try std.testing.expectEqual(expected.notifications, actual.notifications);
    try std.testing.expectEqual(expected.tabs, actual.tabs);
    try std.testing.expectEqual(expected.active_tab, actual.active_tab);
    try std.testing.expectEqual(expected.panes, actual.panes);
    try std.testing.expectEqual(expected.frame, actual.frame);
    try std.testing.expectEqual(expected.pane_metadata, actual.pane_metadata);
    try std.testing.expectEqual(expected.pane_foreground, actual.pane_foreground);
    try std.testing.expectEqual(expected.pane_graphics, actual.pane_graphics);
    try std.testing.expectEqual(expected.chrome, actual.chrome);
    try std.testing.expectEqual(expected.prompt, actual.prompt);
}

fn expectNonViewportVersionEqual(expected: client_model.Version, actual: client_model.Version) !void {
    try std.testing.expectEqual(expected.workspace, actual.workspace);
    try std.testing.expectEqual(expected.configuration, actual.configuration);
    try std.testing.expectEqual(expected.diagnostic, actual.diagnostic);
    try std.testing.expectEqual(expected.host, actual.host);
    try std.testing.expectEqual(expected.host_capabilities, actual.host_capabilities);
    try std.testing.expectEqual(expected.workspace_list, actual.workspace_list);
    try std.testing.expectEqual(expected.agents, actual.agents);
    try std.testing.expectEqual(expected.sidebar_animation, actual.sidebar_animation);
    try std.testing.expectEqual(expected.proxy_status, actual.proxy_status);
    try std.testing.expectEqual(expected.system_metrics, actual.system_metrics);
    try std.testing.expectEqual(expected.notifications, actual.notifications);
    try std.testing.expectEqual(expected.tabs, actual.tabs);
    try std.testing.expectEqual(expected.active_tab, actual.active_tab);
    try std.testing.expectEqual(expected.panes, actual.panes);
    try std.testing.expectEqual(expected.frame, actual.frame);
    try std.testing.expectEqual(expected.pane_metadata, actual.pane_metadata);
    try std.testing.expectEqual(expected.pane_foreground, actual.pane_foreground);
    try std.testing.expectEqual(expected.pane_graphics, actual.pane_graphics);
    try std.testing.expectEqual(expected.chrome, actual.chrome);
    try std.testing.expectEqual(expected.prompt, actual.prompt);
    try std.testing.expectEqual(expected.copy, actual.copy);
}

fn expectOnlyNotificationVersionChanged(expected: client_model.Version, actual: client_model.Version) !void {
    try std.testing.expect(actual.notifications > expected.notifications);

    var normalized = actual;
    normalized.notifications = expected.notifications;
    try std.testing.expectEqualDeep(expected, normalized);
}

// ---------------------------------------------------------------------------
// Test harness: a real Client over substituted platform dependencies — a
// socketpair instead of the runtime socket, a pipe instead of the tty's read
// handle, and a discarding writer instead of the host terminal.

const TestHarness = struct {
    connection: core.transport.SocketChannel,
    peer: core.transport.SocketChannel,
    input_read: File,
    input_write: File,
    sink: Io.Writer.Discarding,
    client: *Client,

    fn init(harness: *TestHarness) !void {
        var sockets: [2]std.c.fd_t = undefined;
        if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sockets) != 0)
            return error.SocketPairFailed;
        harness.connection = .init(.{ .socket = .{
            .handle = sockets[0],
            .address = .{ .ip4 = .loopback(0) },
        } });
        harness.peer = .init(.{ .socket = .{
            .handle = sockets[1],
            .address = .{ .ip4 = .loopback(0) },
        } });
        var pipe_fds: [2]std.c.fd_t = undefined;
        if (std.c.pipe(&pipe_fds) != 0) return error.PipeFailed;
        harness.input_read = .{ .handle = pipe_fds[0], .flags = .{ .nonblocking = false } };
        harness.input_write = .{ .handle = pipe_fds[1], .flags = .{ .nonblocking = false } };
        harness.sink = .init(&.{});
        harness.client = try Client.init(.{
            .gpa = std.testing.allocator,
            .io = std.testing.io,
            .connection = &harness.connection,
            .input_file = harness.input_read,
            .writer = &harness.sink.writer,
            .host_size = .{ .cols = 80, .rows = 24, .cell_width_px = 0, .cell_height_px = 0 },
            .options = .{ .arguments = &.{}, .cwd = "/", .endpoint = "" },
        });
    }

    fn deinit(harness: *TestHarness) void {
        const io = std.testing.io;
        // EOF unblocks a pending input read so task cancellation never has
        // to wait on the pipe.
        harness.input_write.close(io);
        harness.client.deinit();
        harness.peer.deinit(io);
        harness.connection.deinit(io);
        harness.input_read.close(io);
    }

    /// Drives the real dispatch until the outbox is drained, so a test
    /// observes exactly what the runtime peer would receive.
    fn settle(harness: *TestHarness) !void {
        while (harness.client.runtime_transport.outbox.inFlight() or harness.client.runtime_transport.outbox.len != 0) {
            switch (try harness.client.select.await()) {
                .sent => |result| try runtime_transport.handleSent(harness.client, result),
                .draw => |result| try presentation_lifecycle.handleDraw(harness.client, result),
                .sidebar_animation_tick => |result| {
                    _ = try sidebar_animations.handleTick(harness.client, result);
                    try presentation_lifecycle.observe(harness.client);
                },
                .notification_tick => |result| {
                    _ = try notification_flow.handleTick(harness.client, result);
                    try presentation_lifecycle.observe(harness.client);
                },
                else => return error.UnexpectedEvent,
            }
        }
    }

    fn settleModelPresentation(harness: *TestHarness) !void {
        var target = harness.client.model.version();
        const graphics_target = harness.client.graphics_store.ingressVersion();
        const attachment_target = harness.client.view.kittyAttachments().ingressVersion();
        while (!std.meta.eql(harness.client.presenter.presented_model_version, target) or
            harness.client.presenter.presented_graphics_ingress != graphics_target or
            harness.client.presenter.presented_attachment_ingress != attachment_target)
        {
            switch (try harness.client.select.await()) {
                .draw => |result| try presentation_lifecycle.handleDraw(harness.client, result),
                .sent => |result| try runtime_transport.handleSent(harness.client, result),
                .media_tick => |result| try presentation_lifecycle.handleMediaTick(harness.client, result),
                .sidebar_animation_tick => |result| {
                    _ = try sidebar_animations.handleTick(harness.client, result);
                    try presentation_lifecycle.observe(harness.client);
                    target = harness.client.model.version();
                },
                .notification_tick => |result| {
                    _ = try notification_flow.handleTick(harness.client, result);
                    try presentation_lifecycle.observe(harness.client);
                    target = harness.client.model.version();
                },
                else => return error.UnexpectedEvent,
            }
        }
    }

    /// Receives the next message the client sent to the runtime.
    fn nextClientMessage(harness: *TestHarness, buffer: []u8) !schema.ClientMessage {
        const payload = try harness.peer.receive(std.testing.io, buffer);
        return schema.decodeClient(payload);
    }

    fn nextAttachmentRequest(harness: *TestHarness, pane_id: schema.PaneId, buffer: []u8) !schema.RequestId {
        while (true) {
            switch (try harness.nextClientMessage(buffer)) {
                .open_pane => |open| {
                    if (open.target == .pane and open.target.pane == pane_id) {
                        return open.request_id;
                    }

                    return error.UnexpectedPaneTarget;
                },
                .pane_resize, .pane_input, .frame_ack => {},
                else => return error.UnexpectedClientMessage,
            }
        }
    }

    fn discoverAndRequestAttachment(harness: *TestHarness, pane_id: schema.PaneId, buffer: []u8) !schema.RequestId {
        const snapshot = try schema.encodeTabSnapshot(buffer, .{
            .request_id = @enumFromInt(3),
            .location = bootstrap_location,
            .panes = &.{
                .{ .pane_id = bootstrap_pane, .lifecycle = .running },
                .{ .pane_id = pane_id, .lifecycle = .running },
            },
        });
        _ = try server_messages.handleServerMessage(harness.client, try schema.decodeServer(snapshot));
        try harness.settle();

        return harness.nextAttachmentRequest(pane_id, buffer);
    }

    const bootstrap_location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const bootstrap_pane: schema.PaneId = @enumFromInt(10);

    /// Answers the initial open request through the real entrypoint, leaving
    /// the client with one attached pane and its two snapshot requests (ids
    /// 2 and 3) delivered to the peer.
    fn bootstrap(harness: *TestHarness) !void {
        try std.testing.expectEqual(initial_request_id, try request_lifecycle.registerInitial(harness.client));
        var payload: [128]u8 = undefined;
        const opened = try schema.encodePaneOpened(&payload, .{
            .request_id = initial_request_id,
            .pane_id = bootstrap_pane,
            .location = bootstrap_location,
            .created = true,
        });
        try std.testing.expectEqual(
            @as(?u8, null),
            try server_messages.handleServerMessage(harness.client, try schema.decodeServer(opened)),
        );
        try harness.settle();
        var buffer: [256]u8 = undefined;
        const first = try harness.nextClientMessage(&buffer);
        try std.testing.expect(first == .request_workspace_snapshot);
        const second = try harness.nextClientMessage(&buffer);
        try std.testing.expect(second == .request_tab_snapshot);
        try presentation_lifecycle.observe(harness.client);
        try harness.settleModelPresentation();
    }

    fn addTab(harness: *TestHarness, tab_id: schema.TabId, pane_id: schema.PaneId) !schema.TabLocation {
        const location: schema.TabLocation = .{
            .workspace = bootstrap_location.workspace,
            .tab_id = tab_id,
        };

        _ = try harness.client.model.workspace.addCreated(.{
            .location = location,
            .position = @intCast(harness.client.model.workspace.count),
            .label = "second",
            .root_pane_id = pane_id,
        }, .{ .cols = 80, .rows = 24 });

        return location;
    }

    fn addInactiveTab(harness: *TestHarness, tab_id: schema.TabId, pane_id: schema.PaneId) !schema.TabLocation {
        const location = try harness.addTab(tab_id, pane_id);
        const tab = harness.client.model.workspace.find(tab_id).?;
        workspace_capability.tabs.Model.detachAll(tab);
        try harness.client.graphics_store.setPaneVisible(pane_id, false);
        try std.testing.expect(harness.client.model.workspace.select(bootstrap_location.tab_id));

        return location;
    }

    fn allowTabSelection(harness: *TestHarness) !void {
        const continuation = request_lifecycle.consume(harness.client, @enumFromInt(3)) orelse
            return error.MissingBootstrapTabSnapshot;
        try std.testing.expect(continuation == .tab_snapshot);
    }
};

fn encodeTestingAgentSnapshot(buffer: []u8, revision: u64, status: schema.AgentStatus) ![]const u8 {
    return schema.encodeAgentSnapshot(buffer, .{
        .revision = revision,
        .entries = &.{.{
            .pane_id = TestHarness.bootstrap_pane,
            .pane_generation = 1,
            .location = TestHarness.bootstrap_location,
            .pane_index = 3,
            .process_id = 42,
            .session_id = @splat(0),
            .workspace_label = "telar",
            .tab_label = "main",
            .session_title = "Test agent",
            .title_source = .generated,
            .title_state = .ready,
            .cwd_label = "~/sandbox/telar",
            .provider = .claude,
            .status = status,
            .source = .screen,
            .authority = .active,
            .confidence = 1,
            .sequence = revision,
            .observed_at_ms = @intCast(revision),
            .expires_at_ms = @intCast(revision + 1),
        }},
    });
}

fn testingConfigAdoption(number: u64, changed: bool) !config_reloads.Adoption {
    const source = if (changed)
        \\local telar = require("telar")
        \\local config = telar.config({ api_version = 2 })
        \\config.client = {
        \\  prefix = "ctrl+s",
        \\  icons = "nerd-font",
        \\  theme = telar.theme({ base = "catppuccin" }),
        \\  sidebar = { visible = false, renderer = "cells" },
        \\  pane_gaps = false,
        \\  sound = { enabled = false },
        \\  input = { escape_timeout_ms = 40, sequence_timeout_ms = 750 },
        \\}
        \\return config
    else
        \\local telar = require("telar")
        \\return telar.config({ api_version = 2 })
    ;

    return testingConfigAdoptionSource(number, source);
}

fn testingConfigAdoptionSource(number: u64, source: []const u8) !config_reloads.Adoption {
    var diagnostic: lua_config.Diagnostic = .{};
    const generation = try lua_config.Generation.loadSource(
        std.testing.allocator,
        std.testing.io,
        source,
        "@client-reload-test",
        number,
        &diagnostic,
    );
    errdefer generation.deinit();
    const registry = try std.testing.allocator.create(plugin_broker.Registry);
    errdefer std.testing.allocator.destroy(registry);
    registry.* = .{};
    const trust_store = try std.testing.allocator.create(core.plugin.TrustStore);
    errdefer std.testing.allocator.destroy(trust_store);
    trust_store.* = .{};
    const router = try host_inputs.buildRouter(.{
        .prefix = generation.snapshot.prefix,
        .bindings = generation.snapshot.bindingSlice(),
        .escape_timeout_ns = generation.snapshot.input_escape_timeout_ns,
        .sequence_timeout_ns = generation.snapshot.input_sequence_timeout_ns,
    });

    return .{
        .generation = generation,
        .registry = registry,
        .trust_store = trust_store,
        .router = router,
        .sidebar_rendering = generation.snapshot.sidebar_rendering,
    };
}

fn installTestingLuaBinding(client: *Client, source: []const u8) !input_capability.action.Action {
    const adoption = try testingConfigAdoptionSource(1, source);
    std.debug.assert(adoption.generation.snapshot.binding_count == 1);
    const configured = adoption.generation.snapshot.bindings[0].action;
    _ = try config_reloads.apply(client, adoption);

    return configured;
}

const TestingPlugin = struct {
    action: input_capability.action.PluginAction,
    digest: core.plugin.Digest,
};

const testing_plugin_context: lua_config.CallbackContext = .{
    .sidebar_visible = true,
    .tab_count = 1,
    .active_tab_index = 0,
    .pane_count = 1,
    .focused_pane_id = @intFromEnum(TestHarness.bootstrap_pane),
};

fn installTestingPlugin(client: *Client) !TestingPlugin {
    std.debug.assert(client.plugin_registry == null);
    const manifest = try core.plugin.parseManifest(
        client.gpa,
        "{\"api_version\":1,\"id\":\"dev.telar.client-test\",\"version\":\"1\",\"entry\":\"plugin.lua\",\"source\":{\"url\":\"local:test\",\"revision\":\"one\"},\"actions\":[\"run\"],\"capabilities\":[\"runtime.control\"]}",
    );
    const digest: core.plugin.Digest = @splat(7);
    const registry = try client.gpa.create(plugin_broker.Registry);
    registry.* = .{};
    registry.packages[0] = .{
        .manifest = manifest,
        .digest = digest,
        .root_len = 0,
        .entry_len = 0,
    };
    registry.count = 1;
    client.plugin_registry = registry;

    return .{
        .action = .{
            .plugin = core.plugin.stableId(manifest.id()),
            .action = core.plugin.stableId("run"),
        },
        .digest = digest,
    };
}

fn installTestingAttachmentTarget(client: *Client, generation: u64) !attachments.Target {
    const target: attachments.Target = .{
        .pane_id = TestHarness.bootstrap_pane,
        .pane_generation = generation,
    };
    _ = try client.model.reconcileAgentSnapshot(.{
        .revision = generation,
        .agents = &.{agents.AgentInput{
            .key = .{
                .pane_id = target.pane_id,
                .pane_generation = target.pane_generation,
            },
            .location = TestHarness.bootstrap_location,
            .pane_index = 1,
            .provider = .codex,
            .status = .working,
        }},
    });
    _ = try attachment_targets.sync(client);

    return target;
}

fn testingClipboardCapture(client: *Client, execution: client_model.ClipboardCapture, bytes: []const u8) !*attachments.Capture {
    const capture = try client.gpa.create(attachments.Capture);
    errdefer client.gpa.destroy(capture);
    capture.* = .{
        .request = .{
            .target = execution.target,
            .sequence = @intFromEnum(execution.id),
        },
        .png = try client.gpa.dupe(u8, bytes),
        .width = 2,
        .height = 2,
    };
    client.clipboard_capture_resources.orphan = capture;

    return capture;
}

test "host input arriving while no tab exists is dropped, not a crash" {
    // The workspace-handoff window: `tabs.deinit()` has run and the new
    // pane has not been confirmed. A keystroke here used to null-unwrap.
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();

    var chunk: InputChunk = .{};
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
    try std.testing.expect(!client.host_input.read_pending);

    switch (try client.select.await()) {
        .sent => |result| try runtime_transport.handleSent(client, result),
        else => return error.UnexpectedEvent,
    }
    try std.testing.expectEqual(client_outbox.capacity - 1, @as(usize, client.runtime_transport.outbox.len));
    try std.testing.expect(client.runtime_transport.outbox.inFlight());
    try std.testing.expect(client.host_input.read_pending);

    try host_inputs.scheduleRead(client);
    try std.testing.expect(client.host_input.read_pending);
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
    const metrics = try schema.encodeSystemMetrics(&payload, .{
        .revision = 1,
        .cpu_percent = 50,
        .memory_used_decigib = 10,
        .has_battery = false,
        .battery_percent = 0,
    });
    try harness.peer.send(io, metrics);
    switch (try client.select.await()) {
        .server => |result| try std.testing.expectEqual(
            @as(?u8, null),
            try runtime_transport.handleRead(client, result),
        ),
        else => return error.UnexpectedEvent,
    }
    try std.testing.expect(client.runtime_transport.receive_pending);
    try std.testing.expectEqual(@as(u64, 1), client.model.systemMetrics().?.runtime_revision);

    try harness.peer.send(io, try schema.encodeRuntimeStopping(&payload));
    switch (try client.select.await()) {
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
    const pane_id: schema.PaneId = @enumFromInt(7);
    try client.graphics_store.applyImage(.{
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
    try client.graphics_store.applySnapshot(.{
        .pane_id = pane_id,
        .revision = 2,
        .phase = .begin,
    });
    while (client.runtime_transport.outbox.hasCapacity()) {
        try client.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = pane_id } });
    }

    try runtime_transport.flushGraphicsCredits(client);
    try std.testing.expectEqual(@as(usize, 4), client.graphics_store.peekCredit().?.bytes);
    try std.testing.expect(client.runtime_transport.outbox.inFlight());

    switch (try client.select.await()) {
        .sent => |result| try runtime_transport.handleSent(client, result),
        else => return error.UnexpectedEvent,
    }
    try std.testing.expect(client.graphics_store.peekCredit() == null);
    try std.testing.expectEqual(client_outbox.capacity, @as(usize, client.runtime_transport.outbox.len));
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

test "bootstrap answers the initial open with both snapshot requests" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();

    try std.testing.expectEqual(@as(usize, 1), harness.client.model.workspace.count);
    const pane = harness.client.model.workspace.findPane(TestHarness.bootstrap_pane).?;
    try std.testing.expect(pane.attached);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, reportedPaneId(harness.client));
    try std.testing.expectEqual(@as(u64, 1), harness.client.model.version().workspace);
    try std.testing.expectEqual(@as(u64, 1), harness.client.model.version().tabs);
    try std.testing.expectEqual(@as(u64, 1), harness.client.model.version().active_tab);
    try std.testing.expectEqual(@as(u64, 1), harness.client.model.version().panes);
    try std.testing.expectEqualDeep(
        harness.client.model.version(),
        harness.client.presenter.presented_model_version,
    );
}

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

test "pane opening rejects an unknown request without client effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;

    try std.testing.expectError(error.UnexpectedRequest, pane_openings.apply(client, .{
        .request_id = @enumFromInt(99),
        .pane_id = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
        .created = true,
    }));

    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
}

test "pane opening consumes an incompatible continuation before rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: schema.RequestId = @enumFromInt(4);
    const opened: schema.PaneOpened = .{
        .request_id = request_id,
        .pane_id = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
        .created = true,
    };
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;
    try client.request_lifecycle.tracker.add(request_id, .notification);

    try std.testing.expectError(error.UnexpectedRequest, pane_openings.apply(client, opened));
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedRequest, pane_openings.apply(client, opened));
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
}

test "pane opening consumes an ignored continuation without client effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: schema.RequestId = @enumFromInt(4);
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;
    try client.request_lifecycle.tracker.add(request_id, .ignored);

    try std.testing.expectEqual(pane_openings.Outcome.ignored, try pane_openings.apply(client, .{
        .request_id = request_id,
        .pane_id = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
        .created = false,
    }));

    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
}

test "new tab request captures launch source geometry and continuation without mutation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    harness.client.options.arguments = &.{"/bin/sh"};
    const version_before_request = harness.client.model.version();
    const pending_updates_before_request = harness.client.presenter.pending_updates;

    const handler: InputHandler = .{ .client = harness.client };
    _ = try client_actions.apply(handler.client, .new_tab);
    try harness.settle();

    var buffer: [512]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .create_tab);
    const created = message.create_tab;
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location.workspace, created.workspace);
    try std.testing.expectEqualStrings("", created.label);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, created.launch.cwd_source.?);
    try std.testing.expectEqual(schema.TerminalSize{
        .cols = harness.client.view.workbench().w,
        .rows = harness.client.view.workbench().h,
    }, created.size);
    try std.testing.expectEqualDeep(version_before_request, harness.client.model.version());
    try std.testing.expectEqual(pending_updates_before_request, harness.client.presenter.pending_updates);

    const continuation = harness.client.request_lifecycle.tracker.take(created.request_id).?;
    try std.testing.expect(continuation == .create_tab);
    try std.testing.expectEqualDeep(created.workspace, continuation.create_tab.workspace);
    try std.testing.expectEqual(created.size, continuation.create_tab.size);
}

test "new pane inherits cwd from the focused runtime pane" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    harness.client.options.arguments = &.{"/bin/sh"};

    const handler: InputHandler = .{ .client = harness.client };
    _ = try client_actions.apply(handler.client, .{ .split_pane = .horizontal });
    try harness.settle();

    var buffer: [512]u8 = undefined;
    try std.testing.expect((try harness.nextClientMessage(&buffer)) == .pane_resize);
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .create_pane);
    const created = message.create_pane;
    try std.testing.expectEqual(TestHarness.bootstrap_pane, created.launch.cwd_source.?);
}

test "new workspace inherits cwd from the focused runtime pane" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    harness.client.options.arguments = &.{"/bin/sh"};
    harness.client.request_lifecycle.tracker = .{};

    var handler: InputHandler = .{ .client = harness.client };
    _ = try client_actions.apply(handler.client, .new_workspace);
    try handler.forward("agents\r");
    try harness.settle();

    var buffer: [512]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .create_workspace);
    const created = message.create_workspace;
    try std.testing.expectEqualStrings("agents", created.name);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, created.launch.cwd_source.?);
}

test "workspace handoff opens the pane remembered for that workspace" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};

    const destination: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(2) };
    const restored_pane: schema.PaneId = @enumFromInt(77);
    client.navigation_history.remember(.{
        .location = .{ .workspace = destination, .tab_id = @enumFromInt(8) },
        .pane_id = restored_pane,
    });
    const version_before_departure = client.model.version();
    const pending_updates_before_departure = client.presenter.pending_updates;
    const handler: InputHandler = .{ .client = client };
    try client_actions.switchWorkspaceResolved(handler.client, @enumFromInt(2));

    try std.testing.expect(client.model.workspaceLocation() == null);
    try std.testing.expectEqual(@as(usize, 0), client.model.workspace.count);
    try std.testing.expectEqual(version_before_departure.workspace + 1, client.model.version().workspace);
    try std.testing.expectEqual(version_before_departure.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_departure.active_tab + 1, client.model.version().active_tab);
    try std.testing.expectEqual(version_before_departure.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before_departure, client.presenter.pending_updates);
    try std.testing.expect(client.model.reportedPaneFocus() == null);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_departure + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try harness.settle();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
    try std.testing.expectEqual(@as(usize, 0), client.presenter.pending_updates);
    for (client.presenter.screen.front.cells) |cell| {
        try std.testing.expectEqualStrings(" ", cell.text());
        try std.testing.expectEqual(@as(u8, 1), cell.width);
    }
    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(@as(usize, 0), client.presenter.pending_updates);

    var buffer: [256]u8 = undefined;
    var target: ?schema.PaneTarget = null;
    var request_id: schema.RequestId = .none;
    while (target == null) switch (try harness.nextClientMessage(&buffer)) {
        .detach_pane => {},
        .open_pane => |open| {
            request_id = open.request_id;
            target = open.target;
        },
        else => return error.UnexpectedClientMessage,
    };
    try std.testing.expectEqualDeep(schema.PaneTarget{ .pane = restored_pane }, target.?);
    const current = client.navigation_history.find(TestHarness.bootstrap_location.workspace).?;
    try std.testing.expectEqual(TestHarness.bootstrap_pane, current.pane_id);
    try std.testing.expect(current.tab_layout != null);

    var payload: [128]u8 = undefined;
    const failed = try schema.encodeRequestFailed(&payload, .{
        .request_id = request_id,
        .code = .pane_not_found,
        .message = "remembered pane closed",
    });
    const version_before_recovery = client.model.version();
    const pending_updates_before_recovery = client.presenter.pending_updates;
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(failed));

    try std.testing.expectEqualDeep(version_before_recovery, client.model.version());
    try std.testing.expectEqual(pending_updates_before_recovery, client.presenter.pending_updates);
    try harness.settle();
    const fallback = (try harness.nextClientMessage(&buffer)).open_pane;
    try std.testing.expectEqualDeep(
        schema.PaneTarget{ .workspace = @enumFromInt(2) },
        fallback.target,
    );
    const retry = client.request_lifecycle.tracker.take(fallback.request_id).?;
    try std.testing.expect(retry == .initial_open);
    try std.testing.expect(retry.initial_open.fallback_workspace == null);
    try std.testing.expect(client.navigation_history.find(destination) == null);
}

test "workspace handoff capacity failure preserves the source model" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    while (client.runtime_transport.outbox.len < client_outbox.capacity - 1) {
        try client.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }
    const version_before = client.model.version();
    const focus_before = client.model.reportedPaneFocus();
    const handler: InputHandler = .{ .client = client };

    try std.testing.expectError(
        error.ClientOutboxFull,
        client_actions.switchWorkspaceResolved(handler.client, @enumFromInt(2)),
    );

    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expectEqualDeep(focus_before, client.model.reportedPaneFocus());
    try std.testing.expect(client.navigation_history.find(TestHarness.bootstrap_location.workspace) == null);
    try std.testing.expect(client.request_lifecycle.tracker.has(.tab_snapshot));
}

test "workspace handoff reserves its focus-out message" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    client.model.workspace.findPane(TestHarness.bootstrap_pane).?.input_modes.focus_events = true;
    try pane_focus.syncResources(client);
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const focus_in = try harness.nextClientMessage(&buffer);
    try std.testing.expect(focus_in == .pane_input);
    try std.testing.expectEqualStrings("\x1b[I", focus_in.pane_input.bytes);
    while (client.runtime_transport.outbox.len < client_outbox.capacity - 2) {
        try client.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }
    const version = client.model.version();
    const reported = client.model.reportedPaneFocus();

    try std.testing.expectError(
        error.ClientOutboxFull,
        client_actions.switchWorkspaceResolved(client, @enumFromInt(2)),
    );

    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqualDeep(reported, client.model.reportedPaneFocus());
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
}

test "workspace handoff reserves its captured paste closing marker" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    client.model.workspace.findPane(TestHarness.bootstrap_pane).?.input_modes.bracketed_paste = true;
    var input_handler: InputHandler = .{ .client = client };
    try input_handler.pasteStart();
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const opening = try harness.nextClientMessage(&buffer);
    try std.testing.expect(opening == .pane_input);
    try std.testing.expectEqualStrings("\x1b[200~", opening.pane_input.bytes);
    while (client.runtime_transport.outbox.len < client_outbox.capacity - 2) {
        try client.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }
    const version = client.model.version();

    try std.testing.expectError(
        error.ClientOutboxFull,
        client_actions.switchWorkspaceResolved(client, @enumFromInt(2)),
    );

    try std.testing.expect(client.model.panePasteActive());
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
}

test "clicking a sidebar agent hands off directly to its pane" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};

    const agent_pane: schema.PaneId = @enumFromInt(91);
    const agent = agents.AgentInput{
        .key = .{ .pane_id = agent_pane, .pane_generation = 2 },
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(3) },
            .tab_id = @enumFromInt(6),
        },
        .pane_index = 2,
        .provider = .claude,
        .status = .working,
    };
    const left_pane: schema.PaneId = @enumFromInt(90);
    const bottom_right_pane: schema.PaneId = @enumFromInt(92);
    var saved_layout: workspace_capability.layout.Layout = .{};
    try saved_layout.addRoot(left_pane);
    try saved_layout.split(left_pane, agent_pane, .horizontal);
    try saved_layout.split(agent_pane, bottom_right_pane, .vertical);
    client.navigation_history.remember(.{
        .location = agent.location,
        .pane_id = agent_pane,
        .tab_layout = saved_layout,
    });
    _ = try client.model.reconcileAgentSnapshot(.{
        .revision = 1,
        .agents = &.{agent},
    });
    const model = &client.model.workspace.active().?.model;
    _ = try client.view.render(&client.presenter.screen, .{
        .tabs = &client.model.workspace,
        .model = model,
        .agents = client.model.agentSnapshot(),
        .force = true,
    });
    var handler: InputHandler = .{ .client = client };
    try handler.mouse(.{ .x = 4, .y = 4, .kind = .press });
    try harness.settle();

    var buffer: [256]u8 = undefined;
    var target: ?schema.PaneTarget = null;
    var request_id: schema.RequestId = .none;
    while (target == null) switch (try harness.nextClientMessage(&buffer)) {
        .detach_pane => {},
        .open_pane => |open| {
            request_id = open.request_id;
            target = open.target;
        },
        else => return error.UnexpectedClientMessage,
    };
    try std.testing.expectEqualDeep(schema.PaneTarget{ .pane = agent_pane }, target.?);

    var payload: [128]u8 = undefined;
    const opened = try schema.encodePaneOpened(&payload, .{
        .request_id = request_id,
        .pane_id = agent_pane,
        .location = agent.location,
        .created = false,
    });
    const version_before_arrival = client.model.version();
    const pending_updates_before_arrival = client.presenter.pending_updates;
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(opened));

    try std.testing.expectEqual(version_before_arrival.workspace + 1, client.model.version().workspace);
    try std.testing.expectEqual(version_before_arrival.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_arrival.active_tab + 1, client.model.version().active_tab);
    try std.testing.expectEqual(version_before_arrival.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before_arrival, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_arrival + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try harness.settle();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
    try std.testing.expectEqualDeep(
        @as(?schema.WorkspaceLocation, agent.location.workspace),
        client.model.workspace.workspace,
    );
    try std.testing.expectEqual(agent.location.tab_id, client.model.workspace.activeConst().?.location.tab_id);
    try std.testing.expectEqual(agent_pane, client.model.workspace.activeConst().?.model.layout.focused().?);

    var tab_snapshot_request: schema.RequestId = .none;
    while (tab_snapshot_request == .none) switch (try harness.nextClientMessage(&buffer)) {
        .request_workspace_snapshot => {},
        .request_tab_snapshot => |request| {
            try std.testing.expectEqualDeep(agent.location, request.location);
            tab_snapshot_request = request.request_id;
        },
        else => return error.UnexpectedClientMessage,
    };
    var snapshot_payload: [256]u8 = undefined;
    const snapshot = try schema.encodeTabSnapshot(&snapshot_payload, .{
        .request_id = tab_snapshot_request,
        .location = agent.location,
        .panes = &.{
            .{ .pane_id = left_pane, .lifecycle = .running },
            .{ .pane_id = agent_pane, .lifecycle = .running },
            .{ .pane_id = bottom_right_pane, .lifecycle = .running },
        },
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(snapshot));

    const restored = &client.model.workspace.activeConst().?.model;
    try std.testing.expectEqual(agent_pane, restored.layout.focused().?);
    try std.testing.expectEqual(@as(u16, 2), restored.displayIndex(agent_pane).?);
    var expected_geometry: workspace_capability.layout.Snapshot = .{};
    var actual_geometry: workspace_capability.layout.Snapshot = .{};
    saved_layout.snapshot(client.view.workbench(), &expected_geometry);
    restored.layout.snapshot(client.view.workbench(), &actual_geometry);
    for ([_]schema.PaneId{ left_pane, agent_pane, bottom_right_pane }) |pane_id|
        try std.testing.expectEqual(
            expected_geometry.find(pane_id).?.outer,
            actual_geometry.find(pane_id).?.outer,
        );
}

test "tab snapshots commit pane revisions before attaching and presenting" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;

    const discovered: schema.PaneId = @enumFromInt(11);
    var payload: [256]u8 = undefined;
    const snapshot = try schema.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(3),
        .location = TestHarness.bootstrap_location,
        .panes = &.{
            .{ .pane_id = TestHarness.bootstrap_pane, .lifecycle = .running },
            .{ .pane_id = discovered, .lifecycle = .running },
        },
    });
    try std.testing.expectEqual(
        tab_snapshots.Outcome.applied,
        try tab_snapshots.apply(client, (try schema.decodeServer(snapshot)).tab_snapshot),
    );

    try std.testing.expectEqual(version_before.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(version_before.workspace, client.model.version().workspace);
    try std.testing.expectEqual(version_before.tabs, client.model.version().tabs);
    try std.testing.expectEqual(version_before.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    const committed_version = client.model.version();
    try client.request_lifecycle.tracker.add(@enumFromInt(90), .{ .tab_snapshot = TestHarness.bootstrap_location });
    const repeated = try schema.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(90),
        .location = TestHarness.bootstrap_location,
        .panes = &.{
            .{ .pane_id = TestHarness.bootstrap_pane, .lifecycle = .running },
            .{ .pane_id = discovered, .lifecycle = .running },
        },
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(repeated));

    try std.testing.expectEqualDeep(committed_version, client.model.version());
    try std.testing.expect(client.request_lifecycle.tracker.hasPane(.attachment, discovered));
    try std.testing.expectEqual(@as(usize, 2), client.request_lifecycle.tracker.count);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before + 1, client.presenter.pending_updates);
    try harness.settle();

    const pane = client.model.workspace.findPane(discovered).?;
    try std.testing.expect(!pane.attached);
    var buffer: [256]u8 = undefined;
    var attach_requested = false;
    while (!attach_requested) {
        switch (try harness.nextClientMessage(&buffer)) {
            .open_pane => |open| {
                try std.testing.expectEqualDeep(
                    schema.PaneTarget{ .pane = discovered },
                    open.target,
                );
                attach_requested = true;
            },
            .pane_resize => {},
            else => return error.UnexpectedClientMessage,
        }
    }

    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
}

test "an identical tab snapshot repairs resources without scheduling a frame" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    var payload: [256]u8 = undefined;
    const initial = try schema.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(3),
        .location = TestHarness.bootstrap_location,
        .panes = &.{.{ .pane_id = TestHarness.bootstrap_pane, .lifecycle = .running }},
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(initial));
    try presentation_lifecycle.observe(client);
    try harness.settle();
    try harness.settleModelPresentation();
    const committed_version = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;
    try client.request_lifecycle.tracker.add(@enumFromInt(90), .{ .tab_snapshot = TestHarness.bootstrap_location });
    const unchanged = try schema.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(90),
        .location = TestHarness.bootstrap_location,
        .panes = &.{.{ .pane_id = TestHarness.bootstrap_pane, .lifecycle = .running }},
    });

    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(unchanged));
    try presentation_lifecycle.observe(client);

    try std.testing.expectEqualDeep(committed_version, client.model.version());
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
}

test "tab reconciliation retires removed pane resources and continuations" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    var payload: [256]u8 = undefined;
    const initial = try schema.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(3),
        .location = TestHarness.bootstrap_location,
        .panes = &.{.{ .pane_id = TestHarness.bootstrap_pane, .lifecycle = .running }},
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(initial));
    try harness.settle();

    const retired: schema.PaneId = @enumFromInt(11);
    const model = &client.model.workspace.active().?.model;
    try model.split(
        TestHarness.bootstrap_pane,
        retired,
        TestHarness.bootstrap_location,
        .horizontal,
        client.view.workbench(),
    );
    try pane_focus.syncResources(client);
    try std.testing.expect(client.model.enterCopyMode());
    try client.graphics_store.applyImage(.{
        .pane_id = retired,
        .revision = 1,
        .image = .{
            .key = .{ .image_id = 1, .generation = 1 },
            .format = .rgb,
            .width = 1,
            .height = 1,
            .byte_len = 3,
        },
    });
    try client.request_lifecycle.tracker.add(@enumFromInt(91), .{ .close_pane = .{
        .pane_id = retired,
        .location = TestHarness.bootstrap_location,
    } });
    try client.request_lifecycle.tracker.add(@enumFromInt(90), .{ .tab_snapshot = TestHarness.bootstrap_location });
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;
    const reconciled = try schema.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(90),
        .location = TestHarness.bootstrap_location,
        .panes = &.{.{ .pane_id = TestHarness.bootstrap_pane, .lifecycle = .running }},
    });

    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(reconciled));

    try std.testing.expect(client.model.workspace.findPane(retired) == null);
    try std.testing.expect(!client.graphics_store.hasPaneGraphics(retired));
    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expectEqual(@as(?schema.PaneId, TestHarness.bootstrap_pane), reportedPaneId(client));
    try std.testing.expect(client.request_lifecycle.tracker.take(@enumFromInt(91)).? == .ignored);
    try std.testing.expectEqual(version_before.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before + 1, client.presenter.pending_updates);
}

test "an unexpected tab snapshot is rejected instead of adopted" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();

    const client = harness.client;
    const version_before = client.model.version();
    const request_count_before = client.request_lifecycle.tracker.count;
    const pending_updates_before = client.presenter.pending_updates;
    var payload: [256]u8 = undefined;
    const snapshot = try schema.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(99),
        .location = TestHarness.bootstrap_location,
        .panes = &.{},
    });
    try std.testing.expectError(
        error.UnexpectedTabSnapshot,
        server_messages.handleServerMessage(client, try schema.decodeServer(snapshot)),
    );

    try std.testing.expectEqual(request_count_before, client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "tab snapshot consumes an incompatible continuation before rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: schema.RequestId = @enumFromInt(4);
    try client.request_lifecycle.tracker.add(request_id, .notification);
    var payload: [256]u8 = undefined;
    const encoded = try schema.encodeTabSnapshot(&payload, .{
        .request_id = request_id,
        .location = TestHarness.bootstrap_location,
        .panes = &.{},
    });
    const snapshot = (try schema.decodeServer(encoded)).tab_snapshot;

    try std.testing.expectError(error.UnexpectedTabSnapshot, tab_snapshots.apply(client, snapshot));
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedTabSnapshot, tab_snapshots.apply(client, snapshot));
    try std.testing.expectEqualDeep(client_model.Version{}, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "tab snapshot consumes a mismatched location before rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: schema.RequestId = @enumFromInt(4);
    try client.request_lifecycle.tracker.add(request_id, .{ .tab_snapshot = TestHarness.bootstrap_location });
    var payload: [256]u8 = undefined;
    const encoded = try schema.encodeTabSnapshot(&payload, .{
        .request_id = request_id,
        .location = .{
            .workspace = TestHarness.bootstrap_location.workspace,
            .tab_id = @enumFromInt(2),
        },
        .panes = &.{},
    });

    try std.testing.expectError(
        error.UnexpectedTabSnapshot,
        tab_snapshots.apply(client, (try schema.decodeServer(encoded)).tab_snapshot),
    );
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(client_model.Version{}, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "tab snapshot consumes correlation before a model rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: schema.RequestId = @enumFromInt(4);
    try client.request_lifecycle.tracker.add(request_id, .{ .tab_snapshot = TestHarness.bootstrap_location });
    var payload: [256]u8 = undefined;
    const encoded = try schema.encodeTabSnapshot(&payload, .{
        .request_id = request_id,
        .location = TestHarness.bootstrap_location,
        .panes = &.{},
    });

    try std.testing.expectError(
        error.UnexpectedTab,
        tab_snapshots.apply(client, (try schema.decodeServer(encoded)).tab_snapshot),
    );
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(client_model.Version{}, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "an unexpected workspace snapshot is rejected without effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before = client.model.version();
    const request_count_before = client.request_lifecycle.tracker.count;
    const pending_updates_before = client.presenter.pending_updates;
    var payload: [512]u8 = undefined;
    const encoded = try schema.encodeWorkspaceSnapshot(&payload, .{
        .request_id = @enumFromInt(99),
        .workspace = TestHarness.bootstrap_location.workspace,
        .name = "main",
        .tabs = &.{.{
            .tab_id = TestHarness.bootstrap_location.tab_id,
            .position = 0,
            .pane_count = 1,
            .label = "main",
        }},
    });

    try std.testing.expectError(
        error.UnexpectedWorkspaceSnapshot,
        workspace_snapshots.apply(client, (try schema.decodeServer(encoded)).workspace_snapshot),
    );

    try std.testing.expectEqual(request_count_before, client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "workspace snapshot consumes an incompatible continuation before rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: schema.RequestId = @enumFromInt(4);
    try client.request_lifecycle.tracker.add(request_id, .notification);
    var payload: [512]u8 = undefined;
    const encoded = try schema.encodeWorkspaceSnapshot(&payload, .{
        .request_id = request_id,
        .workspace = TestHarness.bootstrap_location.workspace,
        .name = "main",
        .tabs = &.{.{
            .tab_id = TestHarness.bootstrap_location.tab_id,
            .position = 0,
            .pane_count = 1,
            .label = "main",
        }},
    });
    const snapshot = (try schema.decodeServer(encoded)).workspace_snapshot;

    try std.testing.expectError(error.UnexpectedWorkspaceSnapshot, workspace_snapshots.apply(client, snapshot));
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedWorkspaceSnapshot, workspace_snapshots.apply(client, snapshot));
    try std.testing.expectEqualDeep(client_model.Version{}, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "workspace snapshot consumes a mismatched workspace before rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: schema.RequestId = @enumFromInt(4);
    try client.request_lifecycle.tracker.add(request_id, .{
        .workspace_snapshot = TestHarness.bootstrap_location.workspace,
    });
    var payload: [512]u8 = undefined;
    const encoded = try schema.encodeWorkspaceSnapshot(&payload, .{
        .request_id = request_id,
        .workspace = .{ .workspace = @enumFromInt(2) },
        .name = "other",
        .tabs = &.{.{
            .tab_id = @enumFromInt(2),
            .position = 0,
            .pane_count = 1,
            .label = "main",
        }},
    });

    try std.testing.expectError(
        error.UnexpectedWorkspaceSnapshot,
        workspace_snapshots.apply(client, (try schema.decodeServer(encoded)).workspace_snapshot),
    );
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(client_model.Version{}, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "workspace snapshot consumes correlation before a model rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: schema.RequestId = @enumFromInt(4);
    try client.request_lifecycle.tracker.add(request_id, .{
        .workspace_snapshot = TestHarness.bootstrap_location.workspace,
    });
    var payload: [512]u8 = undefined;
    const encoded = try schema.encodeWorkspaceSnapshot(&payload, .{
        .request_id = request_id,
        .workspace = TestHarness.bootstrap_location.workspace,
        .name = "main",
        .tabs = &.{.{
            .tab_id = TestHarness.bootstrap_location.tab_id,
            .position = 0,
            .pane_count = 1,
            .label = "main",
        }},
    });

    try std.testing.expectError(
        error.UnexpectedWorkspace,
        workspace_snapshots.apply(client, (try schema.decodeServer(encoded)).workspace_snapshot),
    );
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(client_model.Version{}, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "workspace snapshots commit semantic revisions before presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;

    var payload: [512]u8 = undefined;
    const snapshot = try schema.encodeWorkspaceSnapshot(&payload, .{
        .request_id = @enumFromInt(2),
        .workspace = TestHarness.bootstrap_location.workspace,
        .name = "main",
        .tabs = &.{
            .{ .tab_id = @enumFromInt(1), .position = 0, .pane_count = 1, .label = "main" },
            .{ .tab_id = @enumFromInt(2), .position = 1, .pane_count = 1, .label = "second" },
        },
    });
    try workspace_snapshots.apply(client, (try schema.decodeServer(snapshot)).workspace_snapshot);

    try std.testing.expectEqual(@as(usize, 2), client.model.workspace.count);
    try std.testing.expect(client.model.workspace.find(@enumFromInt(2)) != null);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expectEqual(version_before.workspace + 1, client.model.version().workspace);
    try std.testing.expectEqual(version_before.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);

    const version_before_noop = client.model.version();
    const pending_updates_before_noop = client.presenter.pending_updates;
    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{
        .workspace_snapshot = TestHarness.bootstrap_location.workspace,
    });
    const unchanged = try schema.encodeWorkspaceSnapshot(&payload, .{
        .request_id = @enumFromInt(4),
        .workspace = TestHarness.bootstrap_location.workspace,
        .name = "main",
        .tabs = &.{
            .{ .tab_id = @enumFromInt(1), .position = 0, .pane_count = 1, .label = "main" },
            .{ .tab_id = @enumFromInt(2), .position = 1, .pane_count = 1, .label = "second" },
        },
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(unchanged));
    try presentation_lifecycle.observe(client);

    try std.testing.expectEqualDeep(version_before_noop, client.model.version());
    try std.testing.expectEqual(pending_updates_before_noop, client.presenter.pending_updates);
}

test "workspace reconciliation retires removed state and restores the new active tab" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const second = try harness.addInactiveTab(@enumFromInt(2), @enumFromInt(20));
    try client.request_lifecycle.tracker.add(@enumFromInt(90), .{ .rename_tab = TestHarness.bootstrap_location });
    try client.graphics_store.applyImage(.{
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
    try std.testing.expect(client.graphics_store.hasPaneGraphics(TestHarness.bootstrap_pane));
    const pending_updates_before = client.presenter.pending_updates;

    var payload: [512]u8 = undefined;
    const snapshot = try schema.encodeWorkspaceSnapshot(&payload, .{
        .request_id = @enumFromInt(2),
        .workspace = TestHarness.bootstrap_location.workspace,
        .name = "main",
        .tabs = &.{
            .{ .tab_id = second.tab_id, .position = 0, .pane_count = 1, .label = "second" },
        },
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(snapshot));

    try std.testing.expectEqualDeep(second, client.model.activeTabLocation().?);
    try std.testing.expect(!client.graphics_store.hasPaneGraphics(TestHarness.bootstrap_pane));
    try std.testing.expect(client.graphics_store.paneVisible(@enumFromInt(20)));
    try std.testing.expectEqual(@as(?schema.PaneId, @enumFromInt(20)), reportedPaneId(client));
    const version_before_late_snapshot = client.model.version();
    const pending_updates_before_late_snapshot = client.presenter.pending_updates;
    const outbox_len_before_late_snapshot = client.runtime_transport.outbox.len;
    const request_count_before_late_snapshot = client.request_lifecycle.tracker.count;
    const late_snapshot = try schema.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(3),
        .location = TestHarness.bootstrap_location,
        .panes = &.{},
    });
    try std.testing.expectEqual(
        tab_snapshots.Outcome.ignored,
        try tab_snapshots.apply(client, (try schema.decodeServer(late_snapshot)).tab_snapshot),
    );

    try std.testing.expectEqual(request_count_before_late_snapshot - 1, client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before_late_snapshot, client.model.version());
    try std.testing.expectEqual(pending_updates_before_late_snapshot, client.presenter.pending_updates);
    try std.testing.expectEqual(outbox_len_before_late_snapshot, client.runtime_transport.outbox.len);
    try std.testing.expect(client.request_lifecycle.tracker.take(@enumFromInt(90)).? == .ignored);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const requested = try harness.nextClientMessage(&buffer);
    try std.testing.expect(requested == .request_tab_snapshot);
    try std.testing.expectEqualDeep(second, requested.request_tab_snapshot.location);
}

test "resync required requests one workspace snapshot and coalesces repeats" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    client.model.workspace.workspace = TestHarness.bootstrap_location.workspace;
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;
    const required: schema.ResyncRequired = .{
        .workspace = TestHarness.bootstrap_location.workspace,
        .workspace_closed = false,
    };

    try std.testing.expectEqual(
        client_application.resync_required.Outcome.snapshot_requested,
        try resync_requirements.apply(client, required),
    );
    try std.testing.expectEqual(
        client_application.resync_required.Outcome.coalesced,
        try resync_requirements.apply(client, required),
    );
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const first = try harness.nextClientMessage(&buffer);
    try std.testing.expect(first == .request_workspace_snapshot);
    try std.testing.expect(client.request_lifecycle.tracker.has(.workspace_snapshot));
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
}

test "resync rejects a workspace other than the current projection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    client.model.workspace.workspace = TestHarness.bootstrap_location.workspace;
    const next_request_id = client.request_lifecycle.next_request_id;

    try std.testing.expectError(
        error.UnexpectedResync,
        resync_requirements.apply(client, .{
            .workspace = .{ .workspace = @enumFromInt(9) },
            .workspace_closed = false,
        }),
    );
    try std.testing.expectEqual(next_request_id, client.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "resync keeps a closed bookmark forgotten when predecessor handoff is blocked" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    client.navigation_history.remember(.{
        .location = TestHarness.bootstrap_location,
        .pane_id = TestHarness.bootstrap_pane,
    });
    try client.request_lifecycle.tracker.add(@enumFromInt(7), .notification);
    const version_before = client.model.version();

    try std.testing.expectError(
        error.WorkspaceSwitchWhileRequestPending,
        resync_requirements.apply(client, .{
            .workspace = TestHarness.bootstrap_location.workspace,
            .workspace_closed = true,
            .previous_workspace = @enumFromInt(2),
        }),
    );
    try std.testing.expect(
        client.navigation_history.find(TestHarness.bootstrap_location.workspace) == null,
    );
    try std.testing.expectEqual(@as(usize, 1), client.request_lifecycle.tracker.count);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expectEqualDeep(version_before, client.model.version());
}

test "host Enter variants use the keyboard modes received in a pane frame" {
    const cases = [_]struct { modes: schema.frame.InputModes, expected: []const u8 }{
        .{
            .modes = .{ .kitty_keyboard_flags = 5 },
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
    try pane_focus.syncResources(client);
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

test "pane focus commits before reports resize and presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const second: schema.PaneId = @enumFromInt(20);
    const area = client.view.workbench();

    const split = try client.model.commitPaneSplit(.{
        .split = .{
            .target_pane = TestHarness.bootstrap_pane,
            .location = TestHarness.bootstrap_location,
            .axis = .horizontal,
            .area = area,
        },
        .new_pane = second,
    });
    try std.testing.expect(split.disposition == .active);
    const model = &client.model.workspace.active().?.model;
    try std.testing.expect(model.toggleFullscreen());
    model.find(TestHarness.bootstrap_pane).?.input_modes.focus_events = true;
    model.find(second).?.input_modes.focus_events = true;
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();

    _ = client.model.syncReportedPaneFocus().?;
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;
    const handler: InputHandler = .{ .client = client };

    _ = try client_actions.apply(handler.client, .{ .focus_pane = .left });

    try std.testing.expectEqual(TestHarness.bootstrap_pane, model.layout.focused().?);
    try std.testing.expectEqual(version_before.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(version_before.workspace, client.model.version().workspace);
    try std.testing.expectEqual(version_before.tabs, client.model.version().tabs);
    try std.testing.expectEqual(version_before.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    try std.testing.expect(!handler.redraw);
    const expected_size = model.contentSize(TestHarness.bootstrap_pane, area).?;

    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const focus_out = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(focus_out == .pane_input);
    try std.testing.expectEqual(second, focus_out.pane_input.pane_id);
    try std.testing.expectEqualStrings("\x1b[O", focus_out.pane_input.bytes);
    const focus_in = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(focus_in == .pane_input);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, focus_in.pane_input.pane_id);
    try std.testing.expectEqualStrings("\x1b[I", focus_in.pane_input.bytes);
    const resize = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(resize == .pane_resize);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, resize.pane_resize.pane_id);
    try std.testing.expectEqual(expected_size, resize.pane_resize.size);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates_before + 1, client.presenter.pending_updates);
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.observed_model_version);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);

    const version_before_noop = client.model.version();
    const pending_updates_before_noop = client.presenter.pending_updates;
    _ = try client_actions.apply(handler.client, .{ .focus_pane = .left });
    try presentation_lifecycle.observe(client);

    try std.testing.expectEqualDeep(version_before_noop, client.model.version());
    try std.testing.expectEqual(pending_updates_before_noop, client.presenter.pending_updates);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expect(!handler.redraw);
}

test "mouse focus precedes forwarding its triggering press" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const first = TestHarness.bootstrap_pane;
    const second: schema.PaneId = @enumFromInt(20);
    const area = client.view.workbench();

    _ = try client.model.commitPaneSplit(.{
        .split = .{
            .target_pane = first,
            .location = TestHarness.bootstrap_location,
            .axis = .horizontal,
            .area = area,
        },
        .new_pane = second,
    });
    const model = &client.model.workspace.active().?.model;
    model.find(first).?.input_modes.focus_events = true;
    model.find(first).?.mouse = .{ .tracking = .normal, .sgr = true };
    model.find(second).?.input_modes.focus_events = true;
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();

    _ = client.model.syncReportedPaneFocus().?;
    const first_view = model.viewForPane(first, area).?;
    const point = term.Event.Mouse{
        .x = first_view.content.x,
        .y = first_view.content.y,
        .kind = .move,
    };
    var handler: InputHandler = .{ .client = client };
    try handler.mouse(point);
    handler.redraw = false;
    const version_before = client.model.version();
    var press = point;
    press.kind = .press;

    try handler.mouse(press);

    try std.testing.expectEqual(first, model.layout.focused().?);
    try std.testing.expectEqual(version_before.panes + 1, client.model.version().panes);
    try std.testing.expect(!handler.redraw);
    try harness.settle();

    var message_buffer: [256]u8 = undefined;
    const focus_out = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(focus_out == .pane_input);
    try std.testing.expectEqual(second, focus_out.pane_input.pane_id);
    try std.testing.expectEqualStrings("\x1b[O", focus_out.pane_input.bytes);
    const focused_input = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(focused_input == .pane_input);
    try std.testing.expectEqual(first, focused_input.pane_input.pane_id);
    try std.testing.expectEqualStrings("\x1b[I\x1b[<0;1;1M", focused_input.pane_input.bytes);
}

test "pane geometry delivery offers only attached visible panes" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const area = client.view.workbench();
    const active = &client.model.workspace.active().?.model;
    const expected_size = active.contentSize(TestHarness.bootstrap_pane, area).?;

    try pane_geometry.offerAttached(client, active, area);
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const offered = try harness.nextClientMessage(&buffer);
    try std.testing.expect(offered == .pane_resize);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, offered.pane_resize.pane_id);
    try std.testing.expectEqual(expected_size, offered.pane_resize.size);

    const detached_location = try harness.addInactiveTab(@enumFromInt(2), @enumFromInt(20));
    const detached = &client.model.workspace.find(detached_location.tab_id).?.model;
    try pane_geometry.offerAttached(client, detached, area);

    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expect(!client.runtime_transport.outbox.inFlight());
}

test "pane resize publishes committed geometry before presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const first = TestHarness.bootstrap_pane;
    const second: schema.PaneId = @enumFromInt(20);
    const area = client.view.workbench();

    _ = try client.model.commitPaneSplit(.{
        .split = .{
            .target_pane = first,
            .location = TestHarness.bootstrap_location,
            .axis = .horizontal,
            .area = area,
        },
        .new_pane = second,
    });
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    const model = &client.model.workspace.active().?.model;
    const first_before = model.contentSize(first, area).?;
    const second_before = model.contentSize(second, area).?;
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;
    const handler: InputHandler = .{ .client = client };

    _ = try client_actions.apply(handler.client, .{ .resize_pane = .left });

    const first_after = model.contentSize(first, area).?;
    const second_after = model.contentSize(second, area).?;
    try std.testing.expect(first_after.cols < first_before.cols);
    try std.testing.expect(second_after.cols > second_before.cols);
    try std.testing.expectEqual(second, model.layout.focused().?);
    try std.testing.expectEqual(version_before.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(version_before.workspace, client.model.version().workspace);
    try std.testing.expectEqual(version_before.tabs, client.model.version().tabs);
    try std.testing.expectEqual(version_before.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    try std.testing.expect(model.composition_invalidated);
    try std.testing.expect(!client.view.dirty);
    try std.testing.expect(!handler.redraw);

    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const first_resize = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(first_resize == .pane_resize);
    try std.testing.expectEqual(first, first_resize.pane_resize.pane_id);
    try std.testing.expectEqual(first_after, first_resize.pane_resize.size);
    const second_resize = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(second_resize == .pane_resize);
    try std.testing.expectEqual(second, second_resize.pane_resize.pane_id);
    try std.testing.expectEqual(second_after, second_resize.pane_resize.size);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates_before + 1, client.presenter.pending_updates);
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.observed_model_version);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);

    const version_before_noop = client.model.version();
    const pending_updates_before_noop = client.presenter.pending_updates;
    _ = try client_actions.apply(handler.client, .{ .resize_pane = .up });
    try presentation_lifecycle.observe(client);

    try std.testing.expectEqualDeep(version_before_noop, client.model.version());
    try std.testing.expectEqual(pending_updates_before_noop, client.presenter.pending_updates);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expect(!client.view.dirty);
    try std.testing.expect(!handler.redraw);
}

test "pane fullscreen publishes visible geometry without direct redraw" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const first = TestHarness.bootstrap_pane;
    const second: schema.PaneId = @enumFromInt(20);
    const area = client.view.workbench();

    _ = try client.model.commitPaneSplit(.{
        .split = .{
            .target_pane = first,
            .location = TestHarness.bootstrap_location,
            .axis = .horizontal,
            .area = area,
        },
        .new_pane = second,
    });
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    const model = &client.model.workspace.active().?.model;
    const first_tiled = model.contentSize(first, area).?;
    const second_tiled = model.contentSize(second, area).?;
    const version_before_enter = client.model.version();
    const pending_updates_before_enter = client.presenter.pending_updates;
    const handler: InputHandler = .{ .client = client };

    _ = try client_actions.apply(handler.client, .toggle_pane_fullscreen);

    try std.testing.expect(model.layout.isFullscreen());
    try std.testing.expect(model.contentSize(first, area) == null);
    const fullscreen_size = model.contentSize(second, area).?;
    try std.testing.expectEqual(schema.TerminalSize{ .cols = area.w, .rows = area.h }, fullscreen_size);
    try std.testing.expectEqual(version_before_enter.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before_enter, client.presenter.pending_updates);
    try std.testing.expect(model.composition_invalidated);
    try std.testing.expect(!client.view.dirty);
    try std.testing.expect(!handler.redraw);

    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const fullscreen_resize = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(fullscreen_resize == .pane_resize);
    try std.testing.expectEqual(second, fullscreen_resize.pane_resize.pane_id);
    try std.testing.expectEqual(fullscreen_size, fullscreen_resize.pane_resize.size);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates_before_enter + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);

    const version_before_exit = client.model.version();
    const pending_updates_before_exit = client.presenter.pending_updates;
    _ = try client_actions.apply(handler.client, .toggle_pane_fullscreen);

    try std.testing.expect(!model.layout.isFullscreen());
    try std.testing.expectEqual(first_tiled, model.contentSize(first, area).?);
    try std.testing.expectEqual(second_tiled, model.contentSize(second, area).?);
    try std.testing.expectEqual(version_before_exit.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before_exit, client.presenter.pending_updates);
    try std.testing.expect(!client.view.dirty);
    try std.testing.expect(!handler.redraw);

    try harness.settle();
    const first_resize = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(first_resize == .pane_resize);
    try std.testing.expectEqual(first, first_resize.pane_resize.pane_id);
    try std.testing.expectEqual(first_tiled, first_resize.pane_resize.size);
    const second_resize = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(second_resize == .pane_resize);
    try std.testing.expectEqual(second, second_resize.pane_resize.pane_id);
    try std.testing.expectEqual(second_tiled, second_resize.pane_resize.size);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates_before_exit + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
}

test "sidebar toggle commits chrome before geometry and presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const shown_area = client.view.workbench();
    const version_before_hide = client.model.version();
    const pending_updates_before_hide = client.presenter.pending_updates;
    const handler: InputHandler = .{ .client = client };

    _ = try client_actions.apply(handler.client, .toggle_sidebar);

    const hidden_area = client.view.workbench();
    try std.testing.expect(hidden_area.w > shown_area.w);
    try std.testing.expect(!client.model.sidebarVisible());
    try std.testing.expect(!client.view.sidebar_requested);
    try std.testing.expectEqual(version_before_hide.chrome + 1, client.model.version().chrome);
    try std.testing.expectEqual(version_before_hide.workspace, client.model.version().workspace);
    try std.testing.expectEqual(version_before_hide.tabs, client.model.version().tabs);
    try std.testing.expectEqual(version_before_hide.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(version_before_hide.panes, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before_hide, client.presenter.pending_updates);
    try std.testing.expect(client.view.dirty);
    try std.testing.expect(!handler.redraw);

    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const expanded = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(expanded == .pane_resize);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, expanded.pane_resize.pane_id);
    try std.testing.expectEqual(
        schema.TerminalSize{ .cols = hidden_area.w, .rows = hidden_area.h },
        expanded.pane_resize.size,
    );

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_hide + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
    try std.testing.expect(!client.view.dirty);

    const version_before_show = client.model.version();
    const pending_updates_before_show = client.presenter.pending_updates;
    _ = try client_actions.apply(handler.client, .toggle_sidebar);

    try std.testing.expect(client.model.sidebarVisible());
    try std.testing.expect(client.view.sidebar_requested);
    try std.testing.expectEqualDeep(shown_area, client.view.workbench());
    try std.testing.expectEqual(version_before_show.chrome + 1, client.model.version().chrome);
    try std.testing.expectEqual(pending_updates_before_show, client.presenter.pending_updates);
    try std.testing.expect(!handler.redraw);

    try harness.settle();
    const contracted = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(contracted == .pane_resize);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, contracted.pane_resize.pane_id);
    try std.testing.expectEqual(
        schema.TerminalSize{ .cols = shown_area.w, .rows = shown_area.h },
        contracted.pane_resize.size,
    );

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_show + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
}

test "sidebar projection rejects changes that are not the current model commit" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    client.view.dirty = false;
    client.graphics_store.damage = false;
    const shown_area = client.view.workbench();
    const committed = client.model.toggleSidebar();

    try std.testing.expectError(error.UnexpectedSidebarVisibility, sidebar_projection.apply(client, .{
        .visible = true,
        .chrome_revision = committed.chrome_revision - 1,
    }));
    try std.testing.expectError(error.UnexpectedSidebarVisibility, sidebar_projection.apply(client, .{
        .visible = committed.visible,
        .chrome_revision = committed.chrome_revision - 1,
    }));

    try std.testing.expect(client.view.sidebar_requested);
    try std.testing.expectEqualDeep(shown_area, client.view.workbench());
    try std.testing.expect(!client.view.dirty);
    try std.testing.expect(!client.graphics_store.damage);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);

    try sidebar_projection.apply(client, committed);

    try std.testing.expect(!client.view.sidebar_requested);
    try std.testing.expect(client.view.workbench().w > shown_area.w);
    try std.testing.expect(client.view.dirty);
    try std.testing.expect(client.graphics_store.damage);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "workspace list toggle is projected only by the presenter" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before_collapse = client.model.version();
    const pending_updates_before_collapse = client.presenter.pending_updates;
    const handler: InputHandler = .{ .client = client };

    _ = try client_actions.apply(handler.client, .toggle_workspace_list);

    try std.testing.expect(client.model.workspaceListCollapsed());
    try std.testing.expect(!client.view.workspace_list_collapsed);
    try std.testing.expectEqual(version_before_collapse.chrome + 1, client.model.version().chrome);
    try std.testing.expectEqual(version_before_collapse.workspace, client.model.version().workspace);
    try std.testing.expectEqual(version_before_collapse.tabs, client.model.version().tabs);
    try std.testing.expectEqual(version_before_collapse.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(version_before_collapse.panes, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before_collapse, client.presenter.pending_updates);
    try std.testing.expect(!client.view.dirty);
    try std.testing.expect(!handler.redraw);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_collapse + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expect(client.view.workspace_list_collapsed);
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);

    const version_before_expand = client.model.version();
    const pending_updates_before_expand = client.presenter.pending_updates;
    _ = try client_actions.apply(handler.client, .toggle_workspace_list);

    try std.testing.expect(!client.model.workspaceListCollapsed());
    try std.testing.expect(client.view.workspace_list_collapsed);
    try std.testing.expectEqual(version_before_expand.chrome + 1, client.model.version().chrome);
    try std.testing.expectEqual(pending_updates_before_expand, client.presenter.pending_updates);
    try std.testing.expect(!handler.redraw);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_expand + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expect(!client.view.workspace_list_collapsed);
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
}

test "an active split commits once and presentation observes the model" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    const split_pane: schema.PaneId = @enumFromInt(21);
    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{ .split = .{
        .target_pane = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
        .axis = .horizontal,
        .area = client.view.workbench(),
    } });
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;
    var payload: [128]u8 = undefined;
    const opened = try schema.encodePaneOpened(&payload, .{
        .request_id = @enumFromInt(4),
        .pane_id = split_pane,
        .location = TestHarness.bootstrap_location,
        .created = true,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(opened));

    const pane = client.model.workspace.findPane(split_pane).?;
    try std.testing.expect(pane.attached);
    try std.testing.expectEqual(split_pane, client.model.workspace.active().?.model.layout.focused().?);
    try std.testing.expectEqual(version_before.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before + 1, client.presenter.pending_updates);
}

test "an inactive split is retained detached without a visible revision" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const first = client.model.workspace.active().?;
    const second_location = try harness.addTab(@enumFromInt(2), @enumFromInt(20));
    workspace_capability.tabs.Model.detachAll(first);
    try std.testing.expectEqualDeep(second_location, client.model.activeTabLocation().?);

    const split_pane: schema.PaneId = @enumFromInt(21);
    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{ .split = .{
        .target_pane = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
        .axis = .horizontal,
        .area = client.view.workbench(),
    } });
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;
    var payload: [128]u8 = undefined;
    const opened = try schema.encodePaneOpened(&payload, .{
        .request_id = @enumFromInt(4),
        .pane_id = split_pane,
        .location = TestHarness.bootstrap_location,
        .created = true,
    });

    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(opened));

    try std.testing.expect(!client.model.workspace.findPane(split_pane).?.attached);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    try std.testing.expect(!client.graphics_store.paneVisible(split_pane));
    try harness.settle();
    var message_buffer: [128]u8 = undefined;
    const detached = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(split_pane, detached.detach_pane.pane_id);
}

test "a split reply for a retired tab detaches and refreshes canonical state" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    _ = client.request_lifecycle.tracker.take(@enumFromInt(2)) orelse return error.MissingWorkspaceSnapshot;
    _ = try harness.addTab(@enumFromInt(2), @enumFromInt(20));

    const split_pane: schema.PaneId = @enumFromInt(21);
    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{ .split = .{
        .target_pane = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
        .axis = .horizontal,
        .area = client.view.workbench(),
    } });
    client.request_lifecycle.tracker.ignoreTab(TestHarness.bootstrap_location.tab_id);
    try std.testing.expect(client.model.workspace.remove(TestHarness.bootstrap_location.tab_id));
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;
    var payload: [128]u8 = undefined;
    const opened = try schema.encodePaneOpened(&payload, .{
        .request_id = @enumFromInt(4),
        .pane_id = split_pane,
        .location = TestHarness.bootstrap_location,
        .created = true,
    });

    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(opened));

    try std.testing.expect(client.model.workspace.findPane(split_pane) == null);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const detached = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(split_pane, detached.detach_pane.pane_id);
    const refresh = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(refresh == .request_workspace_snapshot);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location.workspace, refresh.request_workspace_snapshot.workspace);
}

test "a split reply replaces its target after canonical retirement" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    const split_pane: schema.PaneId = @enumFromInt(21);
    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{ .split = .{
        .target_pane = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
        .axis = .horizontal,
        .area = client.view.workbench(),
    } });
    try std.testing.expect(client.model.workspace.active().?.model.removePane(TestHarness.bootstrap_pane));
    client.request_lifecycle.tracker.ignorePane(TestHarness.bootstrap_pane);
    const version_before = client.model.version();
    var payload: [128]u8 = undefined;
    const opened = try schema.encodePaneOpened(&payload, .{
        .request_id = @enumFromInt(4),
        .pane_id = split_pane,
        .location = TestHarness.bootstrap_location,
        .created = true,
    });

    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(opened));

    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane) == null);
    try std.testing.expect(client.model.workspace.findPane(split_pane).?.attached);
    try std.testing.expectEqual(version_before.panes + 1, client.model.version().panes);
}

test "a failed split never resizes the tab selected afterwards" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const first = client.model.workspace.active().?;
    _ = try harness.addTab(@enumFromInt(2), @enumFromInt(20));
    workspace_capability.tabs.Model.detachAll(first);

    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{ .split = .{
        .target_pane = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
        .axis = .horizontal,
        .area = client.view.workbench(),
    } });
    const version_before = client.model.version();
    var payload: [128]u8 = undefined;
    const failed = try schema.encodeRequestFailed(&payload, .{
        .request_id = @enumFromInt(4),
        .code = .internal,
        .message = "launch failed",
    });

    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(failed));

    try std.testing.expectEqual(@as(u8, 0), client.runtime_transport.outbox.len);
    try expectOnlyNotificationVersionChanged(version_before, client.model.version());
}

test "a failed split for a retired target is silent" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{ .split = .{
        .target_pane = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
        .axis = .horizontal,
        .area = client.view.workbench(),
    } });
    try std.testing.expect(client.model.workspace.active().?.model.removePane(TestHarness.bootstrap_pane));
    client.request_lifecycle.tracker.ignorePane(TestHarness.bootstrap_pane);
    const pending_updates_before = client.presenter.pending_updates;
    var payload: [128]u8 = undefined;
    const failed = try schema.encodeRequestFailed(&payload, .{
        .request_id = @enumFromInt(4),
        .code = .pane_not_found,
        .message = "target exited",
    });

    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(failed));

    try std.testing.expectEqual(@as(u8, 0), client.runtime_transport.outbox.len);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
}

test "an attach reply marks the discovered pane attached" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    const discovered: schema.PaneId = @enumFromInt(11);
    var payload: [256]u8 = undefined;
    const attachment_request = try harness.discoverAndRequestAttachment(discovered, &payload);
    try std.testing.expect(!client.model.workspace.findPane(discovered).?.attached);

    const version_before_confirmation = client.model.version();
    const pending_updates_before_confirmation = client.presenter.pending_updates;

    const opened = try schema.encodePaneOpened(&payload, .{
        .request_id = attachment_request,
        .pane_id = discovered,
        .location = TestHarness.bootstrap_location,
        .created = false,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(opened));

    try std.testing.expect(client.model.workspace.findPane(discovered).?.attached);
    try std.testing.expectEqualDeep(version_before_confirmation, client.model.version());
    try std.testing.expectEqual(pending_updates_before_confirmation, client.presenter.pending_updates);
}

test "tab detachment retires an in-flight pane attachment" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    const discovered: schema.PaneId = @enumFromInt(11);
    var payload: [256]u8 = undefined;
    const attachment_request = try harness.discoverAndRequestAttachment(discovered, &payload);
    try tab_attachments.detach(client, client.model.workspace.active().?);
    try harness.settle();

    var message_buffer: [256]u8 = undefined;
    var detached_root = false;
    var detached_discovered = false;
    for (0..2) |_| {
        const message = try harness.nextClientMessage(&message_buffer);
        try std.testing.expect(message == .detach_pane);
        if (message.detach_pane.pane_id == TestHarness.bootstrap_pane) {
            detached_root = true;
        } else if (message.detach_pane.pane_id == discovered) {
            detached_discovered = true;
        } else {
            return error.UnexpectedDetachedPane;
        }
    }
    try std.testing.expect(detached_root);
    try std.testing.expect(detached_discovered);
    try std.testing.expect(!client.request_lifecycle.tracker.hasPane(.attachment, discovered));

    const pending_updates_before_confirmation = client.presenter.pending_updates;
    const opened = try schema.encodePaneOpened(&payload, .{
        .request_id = attachment_request,
        .pane_id = discovered,
        .location = TestHarness.bootstrap_location,
        .created = false,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(opened));

    try std.testing.expect(!client.model.workspace.findPane(discovered).?.attached);
    try std.testing.expectEqual(pending_updates_before_confirmation, client.presenter.pending_updates);
}

test "tab detachment closes a captured bracketed paste before the pane detaches" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.workspace.findPane(TestHarness.bootstrap_pane).?.input_modes.bracketed_paste = true;
    var handler: InputHandler = .{ .client = client };

    try handler.pasteStart();
    try harness.settle();

    var message_buffer: [256]u8 = undefined;
    const opening = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(opening == .pane_input);
    try std.testing.expectEqualStrings("\x1b[200~", opening.pane_input.bytes);

    try tab_attachments.detach(client, client.model.workspace.active().?);

    try std.testing.expect(!client.model.panePasteActive());
    try harness.settle();
    const closing = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(closing == .pane_input);
    try std.testing.expectEqualStrings("\x1b[201~", closing.pane_input.bytes);
    const detached = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, detached.detach_pane.pane_id);
}

test "tab detachment sends focus-out before the pane detaches" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.workspace.findPane(TestHarness.bootstrap_pane).?.input_modes.focus_events = true;

    try pane_focus.syncResources(client);
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const focus_in = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(focus_in == .pane_input);
    try std.testing.expectEqualStrings("\x1b[I", focus_in.pane_input.bytes);

    try tab_attachments.detach(client, client.model.workspace.active().?);

    try std.testing.expect(client.model.reportedPaneFocus() == null);
    try harness.settle();
    const focus_out = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(focus_out == .pane_input);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, focus_out.pane_input.pane_id);
    try std.testing.expectEqualStrings("\x1b[O", focus_out.pane_input.bytes);
    const detached = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, detached.detach_pane.pane_id);
}

test "tab detachment preserves focus reported by another tab" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.model.workspace.findPane(TestHarness.bootstrap_pane).?.input_modes.focus_events = true;
    try pane_focus.syncResources(client);
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const focus_in = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(focus_in == .pane_input);
    try std.testing.expectEqualStrings("\x1b[I", focus_in.pane_input.bytes);

    const inactive_pane: schema.PaneId = @enumFromInt(20);
    const inactive = try harness.addInactiveTab(@enumFromInt(2), inactive_pane);
    const tab = client.model.workspace.find(inactive.tab_id).?;
    tab.model.find(inactive_pane).?.attached = true;
    const reported = client.model.reportedPaneFocus().?;

    try tab_attachments.detach(client, tab);

    try std.testing.expectEqualDeep(reported, client.model.reportedPaneFocus().?);
    try harness.settle();
    const detached = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(inactive_pane, detached.detach_pane.pane_id);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "a missing pane attachment keeps local membership until a canonical snapshot" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    const discovered: schema.PaneId = @enumFromInt(11);
    var payload: [256]u8 = undefined;
    const attachment_request = try harness.discoverAndRequestAttachment(discovered, &payload);
    const version_before_failure = client.model.version();

    const failed = try schema.encodeRequestFailed(&payload, .{
        .request_id = attachment_request,
        .code = .pane_not_found,
        .message = "pane disappeared",
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(failed));

    const pane = client.model.workspace.findPane(discovered) orelse return error.PaneRemovedBeforeSnapshot;
    try std.testing.expect(!pane.attached);
    try expectOnlyNotificationVersionChanged(version_before_failure, client.model.version());
    try std.testing.expect(client.request_lifecycle.tracker.has(.tab_snapshot));
    try harness.settle();

    var message_buffer: [256]u8 = undefined;
    const recovery = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(recovery == .request_tab_snapshot);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, recovery.request_tab_snapshot.location);
    try std.testing.expect(client.notification_scheduler.pending);
}

test "an internal pane attachment failure waits for a later resync" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    const discovered: schema.PaneId = @enumFromInt(11);
    var payload: [256]u8 = undefined;
    const attachment_request = try harness.discoverAndRequestAttachment(discovered, &payload);
    const version_before_failure = client.model.version();

    const failed = try schema.encodeRequestFailed(&payload, .{
        .request_id = attachment_request,
        .code = .internal,
        .message = "resize failed",
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(failed));

    const pane = client.model.workspace.findPane(discovered) orelse return error.PaneRemovedAfterInternalFailure;
    try std.testing.expect(!pane.attached);
    try expectOnlyNotificationVersionChanged(version_before_failure, client.model.version());
    try std.testing.expect(!client.request_lifecycle.tracker.has(.tab_snapshot));
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expect(client.notification_scheduler.pending);
}

test "a late pane attachment confirmation retired by a snapshot is ignored" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    const discovered: schema.PaneId = @enumFromInt(11);
    var payload: [256]u8 = undefined;
    const attachment_request = try harness.discoverAndRequestAttachment(discovered, &payload);
    try client.request_lifecycle.tracker.add(@enumFromInt(90), .{ .tab_snapshot = TestHarness.bootstrap_location });

    const reconciled = try schema.encodeTabSnapshot(&payload, .{
        .request_id = @enumFromInt(90),
        .location = TestHarness.bootstrap_location,
        .panes = &.{.{ .pane_id = TestHarness.bootstrap_pane, .lifecycle = .running }},
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(reconciled));
    try std.testing.expect(client.model.workspace.findPane(discovered) == null);
    const pending_updates_before_confirmation = client.presenter.pending_updates;

    const opened = try schema.encodePaneOpened(&payload, .{
        .request_id = attachment_request,
        .pane_id = discovered,
        .location = TestHarness.bootstrap_location,
        .created = false,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(opened));

    try std.testing.expectEqual(pending_updates_before_confirmation, client.presenter.pending_updates);
}

test "a late failed pane attachment does not notify or draw" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{ .attach_pane = .{
        .pane_id = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
    } });
    try std.testing.expect(client.request_lifecycle.tracker.ignoreAttachment(TestHarness.bootstrap_pane));
    const pending_updates_before_failure = client.presenter.pending_updates;
    var payload: [256]u8 = undefined;
    const failed = try schema.encodeRequestFailed(&payload, .{
        .request_id = @enumFromInt(4),
        .code = .pane_not_found,
        .message = "pane disappeared",
    });

    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(failed));

    try std.testing.expectEqual(pending_updates_before_failure, client.presenter.pending_updates);
    try std.testing.expect(!client.notification_scheduler.pending);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "a created workspace bookmarks and replaces the prior layout" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    const prior_location = TestHarness.bootstrap_location;
    const left = TestHarness.bootstrap_pane;
    const top_right: schema.PaneId = @enumFromInt(11);
    const bottom_right: schema.PaneId = @enumFromInt(12);
    const workbench = client.view.workbench();
    const prior_model = &client.model.workspace.active().?.model;
    try prior_model.split(left, top_right, prior_location, .horizontal, workbench);
    try prior_model.split(top_right, bottom_right, prior_location, .vertical, workbench);
    prior_model.find(left).?.input_modes.focus_events = true;
    try std.testing.expect(prior_model.focusPane(left));
    _ = client.model.syncReportedPaneFocus().?;
    try std.testing.expect(prior_model.focusPane(bottom_right));
    var expected_geometry: workspace_capability.layout.Snapshot = .{};
    prior_model.layout.snapshot(workbench, &expected_geometry);

    const new_location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = @enumFromInt(5),
    };
    const version_before_creation = client.model.version();
    const pending_updates_before_creation = client.presenter.pending_updates;
    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{ .create_workspace = .{ .cols = 80, .rows = 20 } });
    var payload: [128]u8 = undefined;
    const opened = try schema.encodePaneOpened(&payload, .{
        .request_id = @enumFromInt(4),
        .pane_id = @enumFromInt(30),
        .location = new_location,
        .created = true,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(opened));

    try std.testing.expect(!client.notification_scheduler.pending);
    try std.testing.expectEqualDeep(
        @as(?schema.WorkspaceLocation, new_location.workspace),
        client.model.workspace.workspace,
    );
    const created_pane = client.model.workspace.findPane(@enumFromInt(30)).?;
    try std.testing.expectEqual(@as(u16, 80), created_pane.buffer.w);
    try std.testing.expectEqual(@as(u16, 20), created_pane.buffer.h);
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane) == null);
    try std.testing.expectEqual(version_before_creation.workspace + 1, client.model.version().workspace);
    try std.testing.expectEqual(version_before_creation.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_creation.active_tab + 1, client.model.version().active_tab);
    try std.testing.expectEqual(version_before_creation.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before_creation, client.presenter.pending_updates);
    try std.testing.expectEqual(@as(?schema.PaneId, @enumFromInt(30)), reportedPaneId(client));

    const bookmark = client.navigation_history.find(prior_location.workspace).?;
    try std.testing.expectEqual(prior_location, bookmark.location);
    try std.testing.expectEqual(bottom_right, bookmark.pane_id);
    const saved_layout = bookmark.tab_layout.?;
    var saved_geometry: workspace_capability.layout.Snapshot = .{};
    saved_layout.snapshot(workbench, &saved_geometry);
    for ([_]schema.PaneId{ left, top_right, bottom_right }) |pane_id|
        try std.testing.expectEqual(
            expected_geometry.find(pane_id).?.outer,
            saved_geometry.find(pane_id).?.outer,
        );

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates_before_creation + 1, client.presenter.pending_updates);
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const workspace_snapshot = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(workspace_snapshot == .request_workspace_snapshot);
    try std.testing.expectEqualDeep(new_location.workspace, workspace_snapshot.request_workspace_snapshot.workspace);
    const tab_snapshot = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(tab_snapshot == .request_tab_snapshot);
    try std.testing.expectEqualDeep(new_location, tab_snapshot.request_tab_snapshot.location);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);

    // Return through the same runtime handoff used by workspace selection.
    client.request_lifecycle.tracker = .{};
    const handler: InputHandler = .{ .client = client };
    try client_actions.switchWorkspaceResolved(handler.client, prior_location.workspace.workspace);
    try harness.settle();
    const detached = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(@as(schema.PaneId, @enumFromInt(30)), detached.detach_pane.pane_id);
    const open = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(open == .open_pane);
    try std.testing.expectEqualDeep(schema.PaneTarget{ .pane = bottom_right }, open.open_pane.target);
    const open_request = open.open_pane.request_id;

    const reopened = try schema.encodePaneOpened(&payload, .{
        .request_id = open_request,
        .pane_id = bottom_right,
        .location = prior_location,
        .created = false,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(reopened));
    try harness.settle();
    var snapshot_request: schema.RequestId = .none;
    while (snapshot_request == .none) switch (try harness.nextClientMessage(&message_buffer)) {
        .request_workspace_snapshot => {},
        .request_tab_snapshot => |request| {
            try std.testing.expectEqual(prior_location, request.location);
            snapshot_request = request.request_id;
        },
        else => return error.UnexpectedClientMessage,
    };
    var snapshot_payload: [256]u8 = undefined;
    const snapshot = try schema.encodeTabSnapshot(&snapshot_payload, .{
        .request_id = snapshot_request,
        .location = prior_location,
        .panes = &.{
            .{ .pane_id = left, .lifecycle = .running },
            .{ .pane_id = top_right, .lifecycle = .running },
            .{ .pane_id = bottom_right, .lifecycle = .running },
        },
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(snapshot));

    var restored_geometry: workspace_capability.layout.Snapshot = .{};
    client.model.workspace.activeConst().?.model.layout.snapshot(workbench, &restored_geometry);
    for ([_]schema.PaneId{ left, top_right, bottom_right }) |pane_id|
        try std.testing.expectEqual(
            expected_geometry.find(pane_id).?.outer,
            restored_geometry.find(pane_id).?.outer,
        );
}

test "a failed workspace creation preserves the current projection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const version_before_failure = client.model.version();
    const location_before_failure = client.model.activeTabLocation().?;

    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{ .create_workspace = .{ .cols = 80, .rows = 20 } });
    var payload: [256]u8 = undefined;
    const failed = try schema.encodeRequestFailed(&payload, .{
        .request_id = @enumFromInt(4),
        .code = .spawn_failed,
        .message = "shell launch failed",
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(failed));

    try expectOnlyNotificationVersionChanged(version_before_failure, client.model.version());
    try std.testing.expectEqualDeep(location_before_failure, client.model.activeTabLocation().?);
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane) != null);
    try std.testing.expect(client.notification_scheduler.pending);
}

test "an unexpected tab creation is rejected without effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before = client.model.version();
    const request_count_before = client.request_lifecycle.tracker.count;
    const pending_updates_before = client.presenter.pending_updates;
    const created: schema.TabCreated = .{
        .request_id = @enumFromInt(99),
        .location = .{
            .workspace = TestHarness.bootstrap_location.workspace,
            .tab_id = @enumFromInt(2),
        },
        .position = 1,
        .label = "second",
        .root_pane_id = @enumFromInt(20),
    };

    try std.testing.expectError(error.UnexpectedTabCreated, tab_creations.apply(client, created));

    try std.testing.expectEqual(request_count_before, client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "tab creation consumes an incompatible continuation before rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: schema.RequestId = @enumFromInt(4);
    try client.request_lifecycle.tracker.add(request_id, .notification);
    const created: schema.TabCreated = .{
        .request_id = request_id,
        .location = .{
            .workspace = TestHarness.bootstrap_location.workspace,
            .tab_id = @enumFromInt(2),
        },
        .position = 1,
        .label = "second",
        .root_pane_id = @enumFromInt(20),
    };

    try std.testing.expectError(error.UnexpectedTabCreated, tab_creations.apply(client, created));
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedTabCreated, tab_creations.apply(client, created));
    try std.testing.expectEqualDeep(client_model.Version{}, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "tab creation consumes a mismatched workspace before rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: schema.RequestId = @enumFromInt(4);
    try client.request_lifecycle.tracker.add(request_id, .{ .create_tab = .{
        .workspace = TestHarness.bootstrap_location.workspace,
        .size = .{ .cols = 80, .rows = 20 },
    } });
    const created: schema.TabCreated = .{
        .request_id = request_id,
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(2) },
            .tab_id = @enumFromInt(2),
        },
        .position = 1,
        .label = "second",
        .root_pane_id = @enumFromInt(20),
    };

    try std.testing.expectError(error.UnexpectedTabCreated, tab_creations.apply(client, created));
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(client_model.Version{}, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "tab lifecycle: created, renamed, moved, closed" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    try harness.allowTabSelection();
    const client = harness.client;
    const workspace = TestHarness.bootstrap_location.workspace;
    const second_location: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    const requested_size: schema.TerminalSize = .{
        .cols = client.view.workbench().w - 1,
        .rows = client.view.workbench().h - 1,
    };
    var payload: [256]u8 = undefined;

    // Created: the new tab becomes active and the old one detaches.
    const version_before_creation = client.model.version();
    const pending_updates_before_creation = client.presenter.pending_updates;
    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{ .create_tab = .{
        .workspace = workspace,
        .size = requested_size,
    } });
    const created = try schema.encodeTabCreated(&payload, .{
        .request_id = @enumFromInt(4),
        .location = second_location,
        .position = 1,
        .label = "second",
        .root_pane_id = @enumFromInt(20),
    });
    const creation = try tab_creations.apply(client, (try schema.decodeServer(created)).tab_created);
    @memset(&payload, 'x');

    try std.testing.expect(!client.notification_scheduler.pending);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, creation.previous);
    try std.testing.expectEqualDeep(second_location, creation.created);
    try std.testing.expectEqual(@as(usize, 2), client.model.workspace.count);
    try std.testing.expectEqual(second_location.tab_id, client.model.workspace.active().?.location.tab_id);
    try std.testing.expectEqualStrings("second", client.model.workspace.active().?.labelSlice());
    try std.testing.expectEqual(version_before_creation.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_creation.active_tab + 1, client.model.version().active_tab);
    try std.testing.expectEqual(pending_updates_before_creation, client.presenter.pending_updates);
    try std.testing.expect(!client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    const created_pane = client.model.workspace.findPane(@enumFromInt(20)).?;
    try std.testing.expect(created_pane.attached);
    try std.testing.expectEqual(requested_size.cols, created_pane.buffer.w);
    try std.testing.expectEqual(requested_size.rows, created_pane.buffer.h);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_creation + 1, client.presenter.pending_updates);
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const detached = try harness.nextClientMessage(&buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, detached.detach_pane.pane_id);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);

    // Renamed.
    const version_before_rename = client.model.version();
    const pending_updates_before_rename = client.presenter.pending_updates;
    try client.request_lifecycle.tracker.add(@enumFromInt(5), .{ .rename_tab = second_location });
    const renamed = try schema.encodeTabRenamed(&payload, .{
        .request_id = @enumFromInt(5),
        .location = second_location,
        .label = "renamed",
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(renamed));
    try std.testing.expectEqualStrings(
        "renamed",
        client.model.workspace.find(second_location.tab_id).?.labelSlice(),
    );
    try std.testing.expectEqual(version_before_rename.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_rename.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(pending_updates_before_rename, client.presenter.pending_updates);
    try std.testing.expect(!client.notification_scheduler.pending);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_rename + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);

    // Moved to the front.
    try client.request_lifecycle.tracker.add(@enumFromInt(6), .{ .move_tab = second_location });
    const moved = try schema.encodeTabMoved(&payload, .{
        .request_id = @enumFromInt(6),
        .location = second_location,
        .position = 0,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(moved));
    try std.testing.expectEqual(@as(?usize, 0), client.model.workspace.indexOf(second_location.tab_id));

    // Requested close of the active tab: the semantic commit precedes
    // cleanup, and the presenter observes it independently.
    try client.graphics_store.applyImage(.{ .pane_id = @enumFromInt(20), .revision = 1, .image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgb,
        .width = 1,
        .height = 1,
        .byte_len = 3,
    } });
    try std.testing.expect(client.model.enterCopyMode());
    try std.testing.expect(client.graphics_store.hasPaneGraphics(@enumFromInt(20)));
    const version_before_close = client.model.version();
    const pending_updates_before_close = client.presenter.pending_updates;
    try client.request_lifecycle.tracker.add(@enumFromInt(7), .{ .close_tab = second_location });
    const closed = try schema.encodeTabClosed(&payload, .{
        .request_id = @enumFromInt(7),
        .location = second_location,
        .workspace_closed = false,
    });
    try std.testing.expectEqual(
        @as(?u8, null),
        try server_messages.handleServerMessage(client, try schema.decodeServer(closed)),
    );

    try std.testing.expectEqual(@as(usize, 1), client.model.workspace.count);
    try std.testing.expectEqual(
        TestHarness.bootstrap_location.tab_id,
        client.model.workspace.active().?.location.tab_id,
    );
    try std.testing.expectEqual(version_before_close.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_close.active_tab + 1, client.model.version().active_tab);
    try std.testing.expectEqual(pending_updates_before_close, client.presenter.pending_updates);
    try std.testing.expect(!client.graphics_store.hasPaneGraphics(@enumFromInt(20)));
    try std.testing.expect(!client.model.copyModeActive());

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_close + 1, client.presenter.pending_updates);
    try harness.settle();
    const survivor_snapshot = try harness.nextClientMessage(&buffer);
    try std.testing.expect(survivor_snapshot == .request_tab_snapshot);
    try std.testing.expectEqualDeep(
        TestHarness.bootstrap_location,
        survivor_snapshot.request_tab_snapshot.location,
    );
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);

    // An unknown close request is rejected.
    const unexpected = try schema.encodeTabClosed(&payload, .{
        .request_id = @enumFromInt(99),
        .location = second_location,
        .workspace_closed = false,
    });
    try std.testing.expectError(
        error.UnexpectedTabClosed,
        server_messages.handleServerMessage(client, try schema.decodeServer(unexpected)),
    );
}

test "rejected tab creation leaves the active tab attached" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before_creation = client.model.version();
    const pending_updates_before_creation = client.presenter.pending_updates;
    const request_count_before_creation = client.request_lifecycle.tracker.count;
    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{
        .create_tab = .{
            .workspace = TestHarness.bootstrap_location.workspace,
            .size = .{ .cols = 80, .rows = 20 },
        },
    });
    var payload: [256]u8 = undefined;
    const duplicate = try schema.encodeTabCreated(&payload, .{
        .request_id = @enumFromInt(4),
        .location = TestHarness.bootstrap_location,
        .position = 1,
        .label = "duplicate",
        .root_pane_id = @enumFromInt(20),
    });
    const response = (try schema.decodeServer(duplicate)).tab_created;

    try std.testing.expectError(
        error.TabAlreadyExists,
        tab_creations.apply(client, response),
    );

    try std.testing.expectEqual(request_count_before_creation, client.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedTabCreated, tab_creations.apply(client, response));
    try std.testing.expectEqual(@as(usize, 1), client.model.workspace.count);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expectEqualDeep(version_before_creation, client.model.version());
    try std.testing.expectEqual(pending_updates_before_creation, client.presenter.pending_updates);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "a failed tab creation preserves the current projection and notifies" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before_failure = client.model.version();
    const location_before_failure = client.model.activeTabLocation().?;
    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{ .create_tab = .{
        .workspace = TestHarness.bootstrap_location.workspace,
        .size = .{ .cols = 80, .rows = 20 },
    } });
    var payload: [256]u8 = undefined;
    const failed = try schema.encodeRequestFailed(&payload, .{
        .request_id = @enumFromInt(4),
        .code = .spawn_failed,
        .message = "shell launch failed",
    });

    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(failed));

    try expectOnlyNotificationVersionChanged(version_before_failure, client.model.version());
    try std.testing.expectEqualDeep(location_before_failure, client.model.activeTabLocation().?);
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expect(client.notification_scheduler.pending);
}

test "an unexpected tab move is rejected without effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;
    const moved: schema.TabMoved = .{
        .request_id = @enumFromInt(99),
        .location = TestHarness.bootstrap_location,
        .position = 0,
    };

    try std.testing.expectError(error.UnexpectedTabMoved, tab_moves.apply(client, moved));

    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    try std.testing.expectEqual(@as(?usize, 0), client.model.workspace.indexOf(TestHarness.bootstrap_location.tab_id));
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "tab move consumes an incompatible continuation before rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const request_id: schema.RequestId = @enumFromInt(90);
    const version_before = client.model.version();
    try client.request_lifecycle.tracker.add(request_id, .notification);
    const moved: schema.TabMoved = .{
        .request_id = request_id,
        .location = TestHarness.bootstrap_location,
        .position = 0,
    };

    try std.testing.expectError(error.UnexpectedTabMoved, tab_moves.apply(client, moved));
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedTabMoved, tab_moves.apply(client, moved));
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(@as(?usize, 0), client.model.workspace.indexOf(TestHarness.bootstrap_location.tab_id));
}

test "tab move consumes a canonical response rejected by the model" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const request_id: schema.RequestId = @enumFromInt(90);
    const version_before = client.model.version();
    try client.request_lifecycle.tracker.add(request_id, .{ .move_tab = TestHarness.bootstrap_location });
    const moved: schema.TabMoved = .{
        .request_id = request_id,
        .location = TestHarness.bootstrap_location,
        .position = 1,
    };

    try std.testing.expectError(error.UnexpectedTabMoved, tab_moves.apply(client, moved));
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedTabMoved, tab_moves.apply(client, moved));
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(@as(?usize, 0), client.model.workspace.indexOf(TestHarness.bootstrap_location.tab_id));
}

test "move tab waits for the canonical response and preserves active identity" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const second = try harness.addTab(@enumFromInt(2), @enumFromInt(20));
    const version_before_request = client.model.version();
    const pending_updates_before_request = client.presenter.pending_updates;
    const handler: InputHandler = .{ .client = client };

    _ = try client_actions.apply(handler.client, .{ .move_tab = .previous });

    try std.testing.expectEqual(@as(?usize, 1), client.model.workspace.indexOf(second.tab_id));
    try std.testing.expectEqualDeep(version_before_request, client.model.version());
    try std.testing.expectEqual(pending_updates_before_request, client.presenter.pending_updates);
    try std.testing.expect(!handler.redraw);
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(message == .move_tab);
    try std.testing.expectEqualDeep(second, message.move_tab.location);
    try std.testing.expectEqual(schema.TabMoveDirection.previous, message.move_tab.direction);
    try std.testing.expectEqual(@as(?usize, 1), client.model.workspace.indexOf(second.tab_id));
    const continuation = client.request_lifecycle.tracker.take(message.move_tab.request_id).?;
    try std.testing.expect(continuation == .move_tab);
    try std.testing.expectEqualDeep(second, continuation.move_tab);
    try client.request_lifecycle.tracker.add(message.move_tab.request_id, continuation);

    try std.testing.expect(client.model.workspace.select(TestHarness.bootstrap_location.tab_id));
    const version_before_response = client.model.version();
    const pending_updates_before_response = client.presenter.pending_updates;
    var response_buffer: [256]u8 = undefined;
    const response = try schema.encodeTabMoved(&response_buffer, .{
        .request_id = message.move_tab.request_id,
        .location = second,
        .position = 0,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(response));

    try std.testing.expectEqual(@as(?usize, 0), client.model.workspace.indexOf(second.tab_id));
    try std.testing.expectEqual(TestHarness.bootstrap_location.tab_id, client.model.workspace.activeConst().?.location.tab_id);
    try std.testing.expectEqual(version_before_response.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_response.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(pending_updates_before_response, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqualDeep(client.model.version(), client.presenter.observed_model_version);
    try std.testing.expectEqual(pending_updates_before_response + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
}

test "pending tab operation suppresses a move request" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const second = try harness.addTab(@enumFromInt(2), @enumFromInt(20));
    try client.request_lifecycle.tracker.add(@enumFromInt(90), .{ .rename_tab = second });
    const request_count = client.request_lifecycle.tracker.count;
    const next_request_id = client.request_lifecycle.next_request_id;
    const handler: InputHandler = .{ .client = client };

    _ = try client_actions.apply(handler.client, .{ .move_tab = .previous });

    try std.testing.expectEqual(request_count, client.request_lifecycle.tracker.count);
    try std.testing.expectEqual(next_request_id, client.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expectEqual(@as(?usize, 1), client.model.workspace.indexOf(second.tab_id));
}

test "canonical tab move at an edge does not advance or schedule the model" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const handler: InputHandler = .{ .client = client };

    _ = try client_actions.apply(handler.client, .{ .move_tab = .previous });
    try harness.settle();

    var message_buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(message == .move_tab);
    const version_before_response = client.model.version();
    const pending_updates_before_response = client.presenter.pending_updates;

    var response_buffer: [256]u8 = undefined;
    const response = try schema.encodeTabMoved(&response_buffer, .{
        .request_id = message.move_tab.request_id,
        .location = message.move_tab.location,
        .position = 0,
    });
    try std.testing.expectEqual(
        client_model.Change.unchanged,
        try tab_moves.apply(client, (try schema.decodeServer(response)).tab_moved),
    );
    try presentation_lifecycle.observe(client);

    try std.testing.expectEqualDeep(version_before_response, client.model.version());
    try std.testing.expectEqual(pending_updates_before_response, client.presenter.pending_updates);
    try std.testing.expect(!client.request_lifecycle.tracker.has(.tab_operation));
}

test "tab move response must match the requested identity" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const second = try harness.addTab(@enumFromInt(2), @enumFromInt(20));
    const version_before_response = client.model.version();
    const handler: InputHandler = .{ .client = client };

    _ = try client_actions.apply(handler.client, .{ .move_tab = .previous });
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&message_buffer);
    var response_buffer: [256]u8 = undefined;
    const response = try schema.encodeTabMoved(&response_buffer, .{
        .request_id = message.move_tab.request_id,
        .location = TestHarness.bootstrap_location,
        .position = 0,
    });

    try std.testing.expectError(
        error.UnexpectedTabMoved,
        server_messages.handleServerMessage(client, try schema.decodeServer(response)),
    );

    try std.testing.expectEqual(@as(?usize, 1), client.model.workspace.indexOf(second.tab_id));
    try std.testing.expectEqualDeep(version_before_response, client.model.version());
    try std.testing.expect(!client.request_lifecycle.tracker.has(.tab_operation));
}

test "a failed tab move preserves order and notifies" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const second = try harness.addTab(@enumFromInt(2), @enumFromInt(20));
    const version_before_failure = client.model.version();
    const active_before_failure = client.model.activeTabLocation().?;
    const handler: InputHandler = .{ .client = client };

    _ = try client_actions.apply(handler.client, .{ .move_tab = .previous });
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&message_buffer);
    var response_buffer: [256]u8 = undefined;
    const response = try schema.encodeRequestFailed(&response_buffer, .{
        .request_id = message.move_tab.request_id,
        .code = .tab_not_found,
        .message = "tab not found",
    });

    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(response));

    try std.testing.expectEqual(@as(?usize, 1), client.model.workspace.indexOf(second.tab_id));
    try std.testing.expectEqualDeep(active_before_failure, client.model.activeTabLocation().?);
    try expectOnlyNotificationVersionChanged(version_before_failure, client.model.version());
    try std.testing.expect(!client.request_lifecycle.tracker.has(.tab_operation));
    try std.testing.expect(client.notification_scheduler.pending);
}

test "select tab closes captured paste before detaching and requesting the target snapshot" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    try harness.allowTabSelection();
    const client = harness.client;
    client.model.workspace.findPane(TestHarness.bootstrap_pane).?.input_modes.bracketed_paste = true;
    var handler: InputHandler = .{ .client = client };
    try handler.pasteStart();
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const opening = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(opening == .pane_input);
    try std.testing.expectEqualStrings("\x1b[200~", opening.pane_input.bytes);
    const second_pane: schema.PaneId = @enumFromInt(20);
    const second = try harness.addInactiveTab(@enumFromInt(2), second_pane);
    const selected_model = &client.model.workspace.find(second.tab_id).?.model;
    selected_model.composition_invalidated = false;
    const version_before_selection = client.model.version();
    const pending_updates_before_selection = client.presenter.pending_updates;

    _ = try client_actions.apply(handler.client, .{ .select_tab = 1 });

    try std.testing.expectEqual(second, client.model.activeTabLocation().?);
    try std.testing.expectEqual(version_before_selection.tabs, client.model.version().tabs);
    try std.testing.expectEqual(version_before_selection.active_tab + 1, client.model.version().active_tab);
    try std.testing.expectEqual(pending_updates_before_selection, client.presenter.pending_updates);
    try std.testing.expect(!handler.redraw);
    try std.testing.expect(!selected_model.composition_invalidated);
    try std.testing.expect(!client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expect(!client.model.workspace.findPane(second_pane).?.attached);
    try std.testing.expect(!client.graphics_store.paneVisible(TestHarness.bootstrap_pane));
    try std.testing.expect(client.graphics_store.paneVisible(second_pane));
    try std.testing.expect(!client.model.panePasteActive());

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_selection + 1, client.presenter.pending_updates);
    try harness.settle();

    const closing = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(closing == .pane_input);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, closing.pane_input.pane_id);
    try std.testing.expectEqualStrings("\x1b[201~", closing.pane_input.bytes);
    const detached = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, detached.detach_pane.pane_id);
    const snapshot = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(snapshot == .request_tab_snapshot);
    try std.testing.expectEqualDeep(second, snapshot.request_tab_snapshot.location);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
}

test "tab selection offset wraps while full turns remain no-ops" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    try harness.allowTabSelection();
    const client = harness.client;
    const second = try harness.addInactiveTab(@enumFromInt(2), @enumFromInt(20));
    const version_before_selection = client.model.version();
    const request_id_before_selection = client.request_lifecycle.next_request_id;
    const pending_updates_before_selection = client.presenter.pending_updates;
    const handler: InputHandler = .{ .client = client };

    _ = try client_actions.apply(handler.client, .{ .select_tab_offset = 2 });

    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expectEqualDeep(version_before_selection, client.model.version());
    try std.testing.expectEqual(request_id_before_selection, client.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);

    _ = try client_actions.apply(handler.client, .{ .select_tab_offset = -1 });

    try std.testing.expectEqualDeep(second, client.model.activeTabLocation().?);
    try std.testing.expectEqual(version_before_selection.active_tab + 1, client.model.version().active_tab);
    try std.testing.expectEqual(request_id_before_selection + 1, client.request_lifecycle.next_request_id);
    try std.testing.expect(client.request_lifecycle.tracker.has(.tab_snapshot));
    try std.testing.expectEqual(@as(usize, 2), client.runtime_transport.outbox.len);
    try std.testing.expectEqual(pending_updates_before_selection, client.presenter.pending_updates);
    try std.testing.expect(!handler.redraw);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates_before_selection + 1, client.presenter.pending_updates);
}

test "pending tab snapshot suppresses tab selection without effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const second_pane: schema.PaneId = @enumFromInt(20);
    _ = try harness.addInactiveTab(@enumFromInt(2), second_pane);
    const version_before_selection = client.model.version();
    const next_request_id = client.request_lifecycle.next_request_id;
    const handler: InputHandler = .{ .client = client };

    _ = try client_actions.apply(handler.client, .{ .select_tab = 1 });

    try std.testing.expectEqual(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expect(!client.model.workspace.findPane(second_pane).?.attached);
    try std.testing.expectEqualDeep(version_before_selection, client.model.version());
    try std.testing.expectEqual(next_request_id, client.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expect(!handler.redraw);
}

test "close tab request detaches before delivery and rejection requests restoration" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const version_before_request = client.model.version();
    const pending_updates_before_request = client.presenter.pending_updates;
    const handler: InputHandler = .{ .client = client };

    _ = try client_actions.apply(handler.client, .close_tab);

    try std.testing.expectEqualDeep(version_before_request, client.model.version());
    try std.testing.expectEqual(pending_updates_before_request, client.presenter.pending_updates);
    try std.testing.expect(!handler.redraw);
    try std.testing.expect(!client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);

    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const detached = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, detached.detach_pane.pane_id);
    const requested = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(requested == .close_tab);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, requested.close_tab.location);

    var failure_buffer: [256]u8 = undefined;
    const failed = try schema.encodeRequestFailed(&failure_buffer, .{
        .request_id = requested.close_tab.request_id,
        .code = .internal,
        .message = "close rejected",
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(failed));
    try harness.settle();

    const recovery = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(recovery == .request_tab_snapshot);
    try std.testing.expectEqualDeep(
        TestHarness.bootstrap_location,
        recovery.request_tab_snapshot.location,
    );
    try std.testing.expect(client.notification_scheduler.pending);
    try expectOnlyNotificationVersionChanged(version_before_request, client.model.version());
}

test "close tab capacity failure preserves attachment and request state" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    while (client.runtime_transport.outbox.len < client_outbox.capacity - 1) {
        try client.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }
    const version_before = client.model.version();
    const focus_before = client.model.reportedPaneFocus();
    const next_request_id = client.request_lifecycle.next_request_id;
    const handler: InputHandler = .{ .client = client };

    try std.testing.expectError(
        error.ClientOutboxFull,
        client_actions.apply(handler.client, .close_tab),
    );

    try std.testing.expectEqual(client_outbox.capacity - 1, @as(usize, client.runtime_transport.outbox.len));
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expectEqualDeep(focus_before, client.model.reportedPaneFocus());
    try std.testing.expectEqual(next_request_id, client.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
}

test "close tab reserves its focus-out message" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    client.model.workspace.findPane(TestHarness.bootstrap_pane).?.input_modes.focus_events = true;
    try pane_focus.syncResources(client);
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const focus_in = try harness.nextClientMessage(&buffer);
    try std.testing.expect(focus_in == .pane_input);
    try std.testing.expectEqualStrings("\x1b[I", focus_in.pane_input.bytes);
    while (client.runtime_transport.outbox.len < client_outbox.capacity - 2) {
        try client.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }
    const version = client.model.version();
    const reported = client.model.reportedPaneFocus();
    const next_request_id = client.request_lifecycle.next_request_id;

    try std.testing.expectError(
        error.ClientOutboxFull,
        client_actions.apply(client, .close_tab),
    );

    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqualDeep(reported, client.model.reportedPaneFocus());
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expectEqual(next_request_id, client.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
}

test "close tab reserves its captured paste closing marker" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    client.model.workspace.findPane(TestHarness.bootstrap_pane).?.input_modes.bracketed_paste = true;
    var input_handler: InputHandler = .{ .client = client };
    try input_handler.pasteStart();
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const opening = try harness.nextClientMessage(&buffer);
    try std.testing.expect(opening == .pane_input);
    try std.testing.expectEqualStrings("\x1b[200~", opening.pane_input.bytes);
    while (client.runtime_transport.outbox.len < client_outbox.capacity - 2) {
        try client.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }
    const version = client.model.version();
    const next_request_id = client.request_lifecycle.next_request_id;

    try std.testing.expectError(
        error.ClientOutboxFull,
        client_actions.apply(client, .close_tab),
    );

    try std.testing.expect(client.model.panePasteActive());
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expectEqual(next_request_id, client.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version, client.model.version());
}

test "an unexpected tab closure is rejected without effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;
    const closed: schema.TabClosed = .{
        .request_id = @enumFromInt(99),
        .location = TestHarness.bootstrap_location,
        .workspace_closed = true,
    };

    try std.testing.expectError(error.UnexpectedTabClosed, tab_closures.apply(client, closed));

    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "tab closure consumes an incompatible continuation before rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const request_id: schema.RequestId = @enumFromInt(90);
    const version_before = client.model.version();
    try client.request_lifecycle.tracker.add(request_id, .notification);
    const closed: schema.TabClosed = .{
        .request_id = request_id,
        .location = TestHarness.bootstrap_location,
        .workspace_closed = true,
    };

    try std.testing.expectError(error.UnexpectedTabClosed, tab_closures.apply(client, closed));
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedTabClosed, tab_closures.apply(client, closed));
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
}

test "tab close response must match the requested identity" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const second = try harness.addInactiveTab(@enumFromInt(2), @enumFromInt(20));
    const request_id: schema.RequestId = @enumFromInt(7);
    try client.request_lifecycle.tracker.add(request_id, .{ .close_tab = TestHarness.bootstrap_location });
    const version_before = client.model.version();

    var payload: [128]u8 = undefined;
    const closed = try schema.encodeTabClosed(&payload, .{
        .request_id = request_id,
        .location = second,
        .workspace_closed = false,
    });

    try std.testing.expectError(
        error.UnexpectedTabClosed,
        tab_closures.apply(client, (try schema.decodeServer(closed)).tab_closed),
    );
    try std.testing.expectEqual(@as(usize, 2), client.model.workspace.count);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
}

test "late correlated close after lifecycle removal is ignored" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const second = try harness.addInactiveTab(@enumFromInt(2), @enumFromInt(20));
    const request_id: schema.RequestId = @enumFromInt(7);
    try client.request_lifecycle.tracker.add(request_id, .{ .close_tab = second });

    var payload: [128]u8 = undefined;
    const lifecycle = try schema.encodeTabClosed(&payload, .{
        .request_id = .none,
        .location = second,
        .workspace_closed = false,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(lifecycle));
    const version_after_lifecycle = client.model.version();

    const response = try schema.encodeTabClosed(&payload, .{
        .request_id = request_id,
        .location = second,
        .workspace_closed = false,
    });
    try std.testing.expectEqual(
        tab_closures.Outcome.ignored,
        try tab_closures.apply(client, (try schema.decodeServer(response)).tab_closed),
    );

    try std.testing.expectEqual(@as(usize, 1), client.model.workspace.count);
    try std.testing.expectEqualDeep(version_after_lifecycle, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
}

test "inactive tab lifecycle closure changes only the tab collection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const second_pane: schema.PaneId = @enumFromInt(20);
    const second = try harness.addInactiveTab(@enumFromInt(2), second_pane);
    try client.graphics_store.applyImage(.{ .pane_id = second_pane, .revision = 1, .image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgb,
        .width = 1,
        .height = 1,
        .byte_len = 3,
    } });
    const version_before_close = client.model.version();
    const pending_updates_before_close = client.presenter.pending_updates;

    var payload: [128]u8 = undefined;
    const closed = try schema.encodeTabClosed(&payload, .{
        .request_id = .none,
        .location = second,
        .workspace_closed = false,
    });
    try std.testing.expectEqual(
        tab_closures.Outcome.applied,
        try tab_closures.apply(client, (try schema.decodeServer(closed)).tab_closed),
    );

    try std.testing.expectEqual(@as(usize, 1), client.model.workspace.count);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expectEqual(version_before_close.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_close.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(pending_updates_before_close, client.presenter.pending_updates);
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expect(!client.graphics_store.hasPaneGraphics(second_pane));
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_close + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
}

test "invalid last tab closure has no semantic or cleanup effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    try client.graphics_store.applyImage(.{ .pane_id = TestHarness.bootstrap_pane, .revision = 1, .image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgb,
        .width = 1,
        .height = 1,
        .byte_len = 3,
    } });
    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{ .close_tab = TestHarness.bootstrap_location });
    try client.request_lifecycle.tracker.add(@enumFromInt(90), .{ .tab_snapshot = TestHarness.bootstrap_location });
    const version_before_close = client.model.version();
    const pending_updates_before_close = client.presenter.pending_updates;

    var payload: [128]u8 = undefined;
    const closed = try schema.encodeTabClosed(&payload, .{
        .request_id = @enumFromInt(4),
        .location = TestHarness.bootstrap_location,
        .workspace_closed = false,
    });
    try std.testing.expectError(
        error.UnexpectedWorkspaceRemoval,
        tab_closures.apply(client, (try schema.decodeServer(closed)).tab_closed),
    );

    try std.testing.expectEqual(@as(usize, 1), client.request_lifecycle.tracker.count);
    try std.testing.expectError(
        error.UnexpectedTabClosed,
        tab_closures.apply(client, (try schema.decodeServer(closed)).tab_closed),
    );
    try std.testing.expectEqual(@as(usize, 1), client.model.workspace.count);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expect(client.graphics_store.hasPaneGraphics(TestHarness.bootstrap_pane));
    try std.testing.expectEqualDeep(version_before_close, client.model.version());
    try std.testing.expectEqual(pending_updates_before_close, client.presenter.pending_updates);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expect(client.request_lifecycle.tracker.take(@enumFromInt(90)).? == .tab_snapshot);
}

test "closing the last workspace exits the client" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    try client.graphics_store.applyImage(.{ .pane_id = TestHarness.bootstrap_pane, .revision = 1, .image = .{
        .key = .{ .image_id = 1, .generation = 1 },
        .format = .rgb,
        .width = 1,
        .height = 1,
        .byte_len = 3,
    } });
    const version_before_close = client.model.version();

    var payload: [128]u8 = undefined;
    const closed = try schema.encodeTabClosed(&payload, .{
        .request_id = .none,
        .location = TestHarness.bootstrap_location,
        .workspace_closed = true,
    });
    try std.testing.expectEqual(
        @as(?u8, 0),
        try server_messages.handleServerMessage(client, try schema.decodeServer(closed)),
    );
    try std.testing.expectEqual(@as(usize, 0), client.model.workspace.count);
    try std.testing.expect(client.model.activeTabLocation() == null);
    try std.testing.expectEqual(version_before_close.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_close.active_tab + 1, client.model.version().active_tab);
    try std.testing.expect(!client.graphics_store.hasPaneGraphics(TestHarness.bootstrap_pane));
    try std.testing.expectEqual(@as(?schema.PaneId, null), reportedPaneId(client));
}

test "tab removal follows the runtime predecessor after its workspace disappears" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    client.navigation_history.remember(.{
        .location = TestHarness.bootstrap_location,
        .pane_id = TestHarness.bootstrap_pane,
    });
    const close_request_id: schema.RequestId = @enumFromInt(7);
    try client.request_lifecycle.tracker.add(close_request_id, .{ .close_tab = TestHarness.bootstrap_location });

    var payload: [128]u8 = undefined;
    const closed = try schema.encodeTabClosed(&payload, .{
        .request_id = .none,
        .location = TestHarness.bootstrap_location,
        .workspace_closed = true,
        .previous_workspace = @enumFromInt(2),
    });
    try std.testing.expectEqual(
        @as(?u8, null),
        try server_messages.handleServerMessage(client, try schema.decodeServer(closed)),
    );

    try std.testing.expect(client.model.workspaceLocation() == null);
    try std.testing.expect(client.navigation_history.find(TestHarness.bootstrap_location.workspace) == null);
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .open_pane);
    try std.testing.expectEqualDeep(
        schema.PaneTarget{ .workspace = @enumFromInt(2) },
        message.open_pane.target,
    );
    const continuation = client.request_lifecycle.tracker.take(message.open_pane.request_id).?;
    try std.testing.expect(continuation == .initial_open);
    try std.testing.expectEqual(@as(?schema.WorkspaceId, @enumFromInt(2)), continuation.initial_open.fallback_workspace);
    try std.testing.expect(client.request_lifecycle.tracker.take(close_request_id).? == .ignored);
}

test "resync follows the runtime predecessor after a workspace disappears" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    harness.client.navigation_history.remember(.{
        .location = TestHarness.bootstrap_location,
        .pane_id = TestHarness.bootstrap_pane,
    });

    var payload: [128]u8 = undefined;
    const resync = try schema.encodeResyncRequired(&payload, .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .workspace_closed = true,
        .previous_workspace = @enumFromInt(2),
    });
    try std.testing.expectEqual(
        @as(?u8, null),
        try server_messages.handleServerMessage(harness.client, try schema.decodeServer(resync)),
    );
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .open_pane);
    try std.testing.expectEqualDeep(
        schema.PaneTarget{ .workspace = @enumFromInt(2) },
        message.open_pane.target,
    );
    try std.testing.expect(
        harness.client.navigation_history.find(TestHarness.bootstrap_location.workspace) == null,
    );
}

test "resync forgets the final workspace before exiting" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    client.navigation_history.remember(.{
        .location = TestHarness.bootstrap_location,
        .pane_id = TestHarness.bootstrap_pane,
    });
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;

    var payload: [128]u8 = undefined;
    const resync = try schema.encodeResyncRequired(&payload, .{
        .workspace = TestHarness.bootstrap_location.workspace,
        .workspace_closed = true,
    });

    try std.testing.expectEqual(
        @as(?u8, 0),
        try server_messages.handleServerMessage(client, try schema.decodeServer(resync)),
    );
    try std.testing.expect(
        client.navigation_history.find(TestHarness.bootstrap_location.workspace) == null,
    );
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
}

test "a patch against an unknown base requests a fresh snapshot" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version = client.model.version();
    const pending_updates = client.presenter.pending_updates;
    const frames = client.telemetry.metrics.frames;

    var payload: [512]u8 = undefined;
    const patch = try schema.encodePaneFrame(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .frame_id = 5,
        .base_frame_id = 4,
        .cols = 40,
        .rows = 10,
        .scroll = .{ .total_rows = 10, .offset = 0 },
        .spans = &.{},
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(patch));
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);
    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);
    if (comptime core.diagnostics.enabled) {
        try std.testing.expectEqual(frames, client.telemetry.metrics.frames);
    }

    try harness.settle();
    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .request_snapshot);
    try std.testing.expectEqual(@as(u64, 0), message.request_snapshot.known_frame_id);

    // A full snapshot must carry exactly one span covering the whole grid.
    const blank: core.ui.Cell = .{};
    const cells: [4]core.ui.Cell = @splat(blank);
    try client.graphics_store.setPaneVisible(TestHarness.bootstrap_pane, false);
    const snapshot = try schema.encodePaneFrame(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .frame_id = 5,
        .base_frame_id = 0,
        .cols = 2,
        .rows = 2,
        .scroll = .{ .total_rows = 2, .offset = 0 },
        .spans = &.{.{ .start = 0, .cells = &cells }},
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(snapshot));
    const pane = client.model.workspace.findPane(TestHarness.bootstrap_pane).?;

    try std.testing.expectEqual(
        @as(u64, 5),
        pane.applied_frame_id,
    );
    try std.testing.expectEqual(@as(u64, 5), pane.pending_frame_id);
    try std.testing.expectEqual(version.frame + 1, client.model.version().frame);
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);
    try std.testing.expect(client.graphics_store.paneVisible(TestHarness.bootstrap_pane));
    if (comptime core.diagnostics.enabled) {
        try std.testing.expectEqual(frames + 1, client.telemetry.metrics.frames);
        try std.testing.expectEqual(@as(u64, 1), client.telemetry.metrics.snapshots);
        try std.testing.expectEqual(@as(u64, 1), client.telemetry.metrics.frame_spans);
        try std.testing.expectEqual(@as(u64, 4), client.telemetry.metrics.frame_cells);
    }

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(@as(u64, 0), pane.pending_frame_id);
    try harness.settle();

    const ack = try harness.nextClientMessage(&buffer);
    try std.testing.expect(ack == .frame_ack);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, ack.frame_ack.pane_id);
    try std.testing.expectEqual(@as(u64, 5), ack.frame_ack.frame_id);
}

test "a frame made stale by detach has no state resources or presentation effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const pane = client.model.workspace.findPane(TestHarness.bootstrap_pane).?;
    pane.attached = false;
    const version = client.model.version();
    const pending_updates = client.presenter.pending_updates;
    const graphics_visible = client.graphics_store.paneVisible(TestHarness.bootstrap_pane);
    const frames = client.telemetry.metrics.frames;
    const cells = [_]core.ui.Cell{.{}};
    var payload: [256]u8 = undefined;
    const snapshot = try schema.encodePaneFrame(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .frame_id = 8,
        .base_frame_id = 0,
        .cols = 1,
        .rows = 1,
        .scroll = .{ .total_rows = 1, .offset = 0 },
        .spans = &.{.{ .start = 0, .cells = &cells }},
    });

    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(snapshot));

    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(@as(u64, 0), pane.applied_frame_id);
    try std.testing.expectEqual(@as(u64, 0), pane.pending_frame_id);
    try std.testing.expectEqual(graphics_visible, client.graphics_store.paneVisible(pane.id));
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    if (comptime core.diagnostics.enabled) {
        try std.testing.expectEqual(frames, client.telemetry.metrics.frames);
    }

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);
}

test "pane cwd commits before presenter-owned metadata projection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const active = client.model.workspace.active().?;
    active.model.composition_invalidated = false;
    const version = client.model.version();
    const pending_updates = client.presenter.pending_updates;

    var payload: [128]u8 = undefined;
    const cwd = try schema.encodePaneCwd(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .cwd = "/work/telar",
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(cwd));

    try std.testing.expectEqualStrings(
        "/work/telar",
        client.model.workspace.findPane(TestHarness.bootstrap_pane).?.cwdSlice(),
    );
    try std.testing.expectEqual(version.pane_metadata + 1, client.model.version().pane_metadata);
    try std.testing.expectEqual(version.pane_foreground, client.model.version().pane_foreground);
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);
    try std.testing.expect(!active.model.composition_invalidated);
    try std.testing.expect(!client.view.dirty);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expect(!active.model.composition_invalidated);
    try std.testing.expect(!client.view.dirty);
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);

    const presented_version = client.model.version();
    const presented_updates = client.presenter.pending_updates;
    const same_name = try schema.encodePaneCwd(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .cwd = "/other/telar",
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(same_name));

    try std.testing.expectEqualStrings(
        "/other/telar",
        client.model.workspace.findPane(TestHarness.bootstrap_pane).?.cwdSlice(),
    );
    try std.testing.expectEqualDeep(presented_version, client.model.version());
    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(presented_updates, client.presenter.pending_updates);

    const stale = try schema.encodePaneCwd(&payload, .{
        .pane_id = @enumFromInt(99),
        .cwd = "/missing",
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(stale));
    try std.testing.expectEqualDeep(presented_version, client.model.version());
}

test "pane foreground invalidates compositions only when the presenter observes it" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const inactive_location = try harness.addInactiveTab(@enumFromInt(2), @enumFromInt(20));
    const active = client.model.workspace.active().?;
    const inactive = client.model.workspace.find(inactive_location.tab_id).?;
    active.model.composition_invalidated = false;
    inactive.model.composition_invalidated = false;
    const version = client.model.version();
    const pending_updates = client.presenter.pending_updates;

    var payload: [128]u8 = undefined;
    const foreground = try schema.encodePaneForeground(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .name = "Claude Code",
    });
    _ = try server_messages.handleServerMessage(
        client,
        try schema.decodeServer(foreground),
    );

    try std.testing.expectEqualStrings(
        "Claude Code",
        client.model.workspace.findPane(TestHarness.bootstrap_pane).?.foregroundName(),
    );
    try std.testing.expectEqual(version.pane_metadata + 1, client.model.version().pane_metadata);
    try std.testing.expectEqual(version.pane_foreground + 1, client.model.version().pane_foreground);
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);
    try std.testing.expect(!active.model.composition_invalidated);
    try std.testing.expect(!inactive.model.composition_invalidated);
    try std.testing.expect(!client.view.dirty);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expect(!active.model.composition_invalidated);
    try std.testing.expect(inactive.model.composition_invalidated);
    try std.testing.expect(!client.view.dirty);
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);

    inactive.model.composition_invalidated = false;
    const presented_version = client.model.version();
    const presented_updates = client.presenter.pending_updates;
    _ = try server_messages.handleServerMessage(
        client,
        try schema.decodeServer(foreground),
    );
    try presentation_lifecycle.observe(client);

    try std.testing.expectEqualDeep(presented_version, client.model.version());
    try std.testing.expectEqual(presented_updates, client.presenter.pending_updates);
    try std.testing.expect(!inactive.model.composition_invalidated);
}

test "close pane request waits for the authoritative exit before committing" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const closing_pane: schema.PaneId = @enumFromInt(11);
    const split = try client.model.commitPaneSplit(.{
        .split = .{
            .target_pane = TestHarness.bootstrap_pane,
            .location = TestHarness.bootstrap_location,
            .axis = .horizontal,
            .area = client.view.workbench(),
        },
        .new_pane = closing_pane,
    });
    try std.testing.expect(split.change == .changed);
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    _ = client.model.syncReportedPaneFocus().?;
    try std.testing.expectEqual(closing_pane, client.model.beginPanePaste().?.pane_id);
    try client.graphics_store.applyImage(.{
        .pane_id = closing_pane,
        .revision = 1,
        .image = .{
            .key = .{ .image_id = 1, .generation = 1 },
            .format = .rgb,
            .width = 1,
            .height = 1,
            .byte_len = 3,
        },
    });
    const version_before_request = client.model.version();
    const pending_updates_before_request = client.presenter.pending_updates;
    const handler: InputHandler = .{ .client = client };

    _ = try client_actions.apply(handler.client, .close_pane);

    try std.testing.expect(client.model.workspace.findPane(closing_pane) != null);
    try std.testing.expectEqualDeep(version_before_request, client.model.version());
    try std.testing.expectEqual(pending_updates_before_request, client.presenter.pending_updates);
    try std.testing.expect(!handler.redraw);
    try std.testing.expectEqual(@as(usize, 1), client.request_lifecycle.tracker.count);

    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const requested = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(requested == .close_pane);
    try std.testing.expectEqual(closing_pane, requested.close_pane.pane_id);
    try std.testing.expect(requested.close_pane.request_id != .none);
    try std.testing.expect(!client.model.enterCopyMode());

    var payload: [128]u8 = undefined;
    const exited = try schema.encodePaneExited(&payload, .{
        .pane_id = closing_pane,
        .kind = .exited,
        .value = 0,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(exited));

    try std.testing.expect(client.model.workspace.findPane(closing_pane) == null);
    try std.testing.expectEqual(version_before_request.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before_request, client.presenter.pending_updates);
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expect(!client.model.panePasteActive());
    try std.testing.expectEqual(@as(?schema.PaneId, TestHarness.bootstrap_pane), reportedPaneId(client));
    try std.testing.expect(!client.graphics_store.hasPaneGraphics(closing_pane));
    try std.testing.expect(!client.notification_scheduler.pending);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_request + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
    const committed_version = client.model.version();
    const pending_updates_after_commit = client.presenter.pending_updates;

    const repeated = try pane_closures.applyExit(client, (try schema.decodeServer(exited)).pane_exited);
    try std.testing.expect(repeated == .stale);
    try std.testing.expectEqual(closing_pane, repeated.stale);
    try presentation_lifecycle.observe(client);

    try std.testing.expectEqualDeep(committed_version, client.model.version());
    try std.testing.expectEqual(pending_updates_after_commit, client.presenter.pending_updates);
}

test "an unrequested pane exit removes the pane silently" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    try std.testing.expect(client.model.enterCopyMode());
    try client.graphics_store.applyImage(.{
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
    const version_before_exit = client.model.version();
    const pending_updates_before_exit = client.presenter.pending_updates;

    var payload: [128]u8 = undefined;
    const exited = try schema.encodePaneExited(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .kind = .exited,
        .value = 0,
    });
    const transition = try pane_closures.applyExit(client, (try schema.decodeServer(exited)).pane_exited);
    try std.testing.expect(transition == .retired);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, transition.retired.pane_id);
    try std.testing.expect(transition.retired.active);
    try std.testing.expect(transition.retired.tab_empty);
    try harness.settle();

    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane) == null);
    try std.testing.expectEqual(version_before_exit.panes + 1, client.model.version().panes);
    try std.testing.expectEqual(pending_updates_before_exit, client.presenter.pending_updates);
    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expectEqual(@as(?schema.PaneId, null), reportedPaneId(client));
    try std.testing.expect(!client.graphics_store.hasPaneGraphics(TestHarness.bootstrap_pane));
    try std.testing.expect(!client.notification_scheduler.pending);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_exit + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
}

test "an inactive pane exit retires only inactive state" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const inactive_pane: schema.PaneId = @enumFromInt(20);
    const inactive = try harness.addInactiveTab(@enumFromInt(2), inactive_pane);
    try client.graphics_store.applyImage(.{
        .pane_id = inactive_pane,
        .revision = 1,
        .image = .{
            .key = .{ .image_id = 1, .generation = 1 },
            .format = .rgb,
            .width = 1,
            .height = 1,
            .byte_len = 3,
        },
    });
    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{ .close_pane = .{
        .pane_id = inactive_pane,
        .location = inactive,
    } });
    try client.request_lifecycle.tracker.add(@enumFromInt(5), .{ .attach_pane = .{
        .pane_id = inactive_pane,
        .location = inactive,
    } });
    const version_before_exit = client.model.version();
    const pending_updates_before_exit = client.presenter.pending_updates;

    var payload: [128]u8 = undefined;
    const exited = try schema.encodePaneExited(&payload, .{
        .pane_id = inactive_pane,
        .kind = .signaled,
        .value = 15,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(exited));

    try std.testing.expect(client.model.workspace.findPane(inactive_pane) == null);
    try std.testing.expectEqualDeep(version_before_exit, client.model.version());
    try std.testing.expectEqual(pending_updates_before_exit, client.presenter.pending_updates);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, client.model.activeTabLocation().?);
    try std.testing.expectEqual(@as(?schema.PaneId, TestHarness.bootstrap_pane), reportedPaneId(client));
    try std.testing.expect(!client.graphics_store.hasPaneGraphics(inactive_pane));
    try std.testing.expect(client.request_lifecycle.tracker.take(@enumFromInt(4)) == null);
    try std.testing.expect(client.request_lifecycle.tracker.take(@enumFromInt(5)).? == .ignored);
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_exit + 1, client.presenter.pending_updates);
}

test "a failed request surfaces as a notification" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    try client.request_lifecycle.tracker.add(@enumFromInt(4), .{ .close_pane = .{
        .pane_id = TestHarness.bootstrap_pane,
        .location = TestHarness.bootstrap_location,
    } });
    var payload: [256]u8 = undefined;
    const failed = try schema.encodeRequestFailed(&payload, .{
        .request_id = @enumFromInt(4),
        .code = .pane_not_found,
        .message = "no such pane",
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(failed));
    try harness.settle();
    const notification = client.model.notificationSnapshot().itemAt(0).?;

    try std.testing.expect(client.notification_scheduler.pending);
    try std.testing.expectEqualStrings("Could not close pane", notification.title());
    try std.testing.expectEqualStrings("no such pane", notification.message());
    try std.testing.expectEqualDeep(
        notifications.Target{ .select_tab = TestHarness.bootstrap_location.tab_id },
        notification.target,
    );

    const unknown = try schema.encodeRequestFailed(&payload, .{
        .request_id = @enumFromInt(99),
        .code = .pane_not_found,
        .message = "no such request",
    });
    try std.testing.expectError(
        error.UnexpectedRequestFailure,
        server_messages.handleServerMessage(client, try schema.decodeServer(unknown)),
    );
}

test "a failed snapshot request is fatal after consuming its continuation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: schema.RequestId = @enumFromInt(4);
    try client.request_lifecycle.tracker.add(request_id, .{
        .workspace_snapshot = TestHarness.bootstrap_location.workspace,
    });

    var payload: [256]u8 = undefined;
    const failed = try schema.encodeRequestFailed(&payload, .{
        .request_id = request_id,
        .code = .workspace_not_found,
        .message = "workspace disappeared",
    });

    try std.testing.expectError(
        error.RuntimeRequestFailed,
        server_messages.handleServerMessage(client, try schema.decodeServer(failed)),
    );
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqual(@as(u8, 0), client.model.notificationSnapshot().count);
}

test "a runtime notification translates and owns its wire payload" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;
    var payload: [512]u8 = undefined;
    const encoded = try schema.encodeNotification(&payload, .{
        .level = .warning,
        .duration_ms = 2500,
        .target = .{ .tab = @enumFromInt(3) },
        .title = "Agent waiting",
        .message = "Review its question",
    });

    const publication = try notification_flow.applyRuntime(
        client,
        (try schema.decodeServer(encoded)).notification,
    );
    @memset(&payload, 'x');

    const item = client.model.notificationSnapshot().itemAt(0).?;
    try std.testing.expectEqual(item.id, publication.id);
    try std.testing.expectEqual(version_before.notifications + 1, publication.notifications_revision);
    try std.testing.expectEqual(notifications.Level.warning, item.level);
    try std.testing.expectEqual(
        notifications.Target{ .select_tab = @enumFromInt(3) },
        item.target,
    );
    try std.testing.expectEqualStrings("Agent waiting", item.title());
    try std.testing.expectEqualStrings("Review its question", item.message());
    try std.testing.expectEqual(
        notifications.transition_duration_ns + 2500 * std.time.ns_per_ms,
        item.expires_at_ns - item.transition_updated_ns,
    );
    try std.testing.expectEqual(version_before.notifications + 1, client.model.version().notifications);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    try std.testing.expect(client.notification_scheduler.pending);
}

test "diagnostic notification publication owns one bounded failure notice" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;

    try std.testing.expectError(
        error.ClientDiagnosticMissing,
        notification_flow.publishDiagnostic(client, "Operation failed"),
    );

    _ = try client.model.setDiagnostic("original diagnostic", .{});
    try notification_flow.publishDiagnostic(client, "Operation failed");
    _ = try client.model.setDiagnostic("replacement diagnostic", .{});

    const item = client.model.notificationSnapshot().itemAt(0).?;
    try std.testing.expectEqual(notifications.Level.failure, item.level);
    try std.testing.expectEqualStrings("Operation failed", item.title());
    try std.testing.expectEqualStrings("original diagnostic", item.message());
    try std.testing.expectEqual(
        notifications.transition_duration_ns + 7 * std.time.ns_per_s,
        item.expires_at_ns - item.transition_updated_ns,
    );
    try std.testing.expect(client.notification_scheduler.pending);
}

test "notification timer commits lifecycle state before presenter observation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const now_ns = Client.monotonic(client.io);
    _ = try notification_flow.publish(client, now_ns, .{
        .title = "Building",
        .message = "Lifecycle tick",
    });
    const pending_updates = client.presenter.pending_updates;

    try std.testing.expect(client.notification_scheduler.pending);
    switch (try client.select.await()) {
        .notification_tick => |result| {
            const change = (try notification_flow.handleTick(client, result)).?;

            try std.testing.expectEqual(
                client.model.version().notifications,
                change.notifications_revision,
            );
        },
        else => return error.UnexpectedEvent,
    }

    try std.testing.expect(client.notification_scheduler.pending);
    try std.testing.expectEqual(@as(u64, 2), client.model.version().notifications);
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates + 1, client.presenter.pending_updates);
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.observed_model_version);
}

test "an unexpected notification delivery report is rejected without effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const version_before = client.model.version();
    const shown: schema.NotificationShown = .{
        .request_id = @enumFromInt(99),
        .delivered_clients = 1,
    };

    try std.testing.expectError(
        error.UnexpectedNotificationReply,
        notification_flow.applyDeliveryReport(client, shown),
    );

    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(@as(u8, 0), client.model.notificationSnapshot().count);
    try std.testing.expect(!client.notification_scheduler.pending);
}

test "notification delivery consumes an incompatible continuation before rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: schema.RequestId = @enumFromInt(90);
    try client.request_lifecycle.tracker.add(request_id, .{ .move_tab = TestHarness.bootstrap_location });
    const shown: schema.NotificationShown = .{
        .request_id = request_id,
        .delivered_clients = 1,
    };

    try std.testing.expectError(
        error.UnexpectedNotificationReply,
        notification_flow.applyDeliveryReport(client, shown),
    );
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectError(
        error.UnexpectedNotificationReply,
        notification_flow.applyDeliveryReport(client, shown),
    );
    try std.testing.expectEqual(@as(u8, 0), client.model.notificationSnapshot().count);
    try std.testing.expect(!client.notification_scheduler.pending);
}

test "a delivered notification report consumes correlation without model effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const request_id: schema.RequestId = @enumFromInt(90);
    const version_before = client.model.version();
    try client.request_lifecycle.tracker.add(request_id, .notification);

    try std.testing.expectEqual(
        notification_flow.DeliveryOutcome.delivered,
        try notification_flow.applyDeliveryReport(client, .{
            .request_id = request_id,
            .delivered_clients = 2,
        }),
    );

    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(@as(u8, 0), client.model.notificationSnapshot().count);
    try std.testing.expect(!client.notification_scheduler.pending);
}

test "runtime notifications and delivery failures reach the toasts" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;

    var payload: [256]u8 = undefined;
    const notification = try schema.encodeNotification(&payload, .{ .title = "hello" });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(notification));
    try std.testing.expect(client.notification_scheduler.pending);
    const version_after_runtime = client.model.version();

    try client.request_lifecycle.tracker.add(@enumFromInt(2), .notification);
    const shown = try schema.encodeNotificationShown(&payload, .{
        .request_id = @enumFromInt(2),
        .delivered_clients = 0,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(shown));
    const snapshot = client.model.notificationSnapshot();

    try std.testing.expectEqual(version_after_runtime.notifications + 1, client.model.version().notifications);
    try std.testing.expectEqual(@as(u8, 2), snapshot.count);
    try std.testing.expectEqualStrings("Notification not delivered", snapshot.itemAt(0).?.title());
    try std.testing.expectEqualStrings(
        "No connected client could accept the notification",
        snapshot.itemAt(0).?.message(),
    );
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);

    const unexpected = try schema.encodeNotificationShown(&payload, .{
        .request_id = @enumFromInt(9),
        .delivered_clients = 1,
    });
    try std.testing.expectError(
        error.UnexpectedNotificationReply,
        server_messages.handleServerMessage(client, try schema.decodeServer(unexpected)),
    );
    try harness.settle();
}

test "toast activation commits by id before following its navigation target" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const active = &client.model.workspace.active().?.model;
    const second_pane: schema.PaneId = @enumFromInt(11);
    try active.split(
        TestHarness.bootstrap_pane,
        second_pane,
        TestHarness.bootstrap_location,
        .horizontal,
        client.view.workbench(),
    );
    try std.testing.expect(active.focusPane(TestHarness.bootstrap_pane));

    try notification_flow.publishNow(client, .{
        .title = "Ready",
        .message = "Open pane",
        .target = .{ .focus_pane = second_pane },
    });
    const item = client.model.notificationSnapshot().itemAt(0).?;
    const notification_id = item.id;
    const visible_at_ns = item.transition_updated_ns + notifications.transition_duration_ns;
    _ = client.model.advanceNotifications(visible_at_ns);

    _ = try active.render(&client.presenter.screen, client.view.workbench());
    _ = try client.view.render(&client.presenter.screen, .{
        .model = active,
        .notifications = client.model.notificationSnapshot(),
        .force = true,
    });
    var click: ?term.Event.Mouse = null;
    for (client.view.hits.registered()) |entry| switch (entry.action) {
        .notification_activate => |id| {
            if (id != notification_id) {
                continue;
            }

            click = .{
                .x = entry.rect.x + 1,
                .y = entry.rect.y + 1,
                .kind = .press,
            };
            break;
        },
        else => {},
    };
    const notification_click = click orelse return error.MissingNotificationHit;
    const version_before_activation = client.model.version();
    var handler: InputHandler = .{ .client = client };

    try handler.mouse(notification_click);

    try std.testing.expectEqual(second_pane, active.layout.focused().?);
    try std.testing.expectEqual(
        version_before_activation.notifications + 1,
        client.model.version().notifications,
    );
    const version_after_activation = client.model.version();

    try handler.mouse(notification_click);

    try std.testing.expectEqualDeep(version_after_activation, client.model.version());
}

test "proxy status commits before announcement and presenter-owned projection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;

    var payload: [64]u8 = undefined;
    const enabled = try schema.encodeProxyStatus(&payload, .{ .active = true });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(enabled));

    try std.testing.expect(client.model.proxyTlsActive());
    try std.testing.expectEqual(version_before.proxy_status + 1, client.model.version().proxy_status);
    try std.testing.expectEqual(version_before.notifications + 1, client.model.version().notifications);
    try std.testing.expectEqual(version_before.proxy_status, client.presenter.observed_model_version.proxy_status);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    try std.testing.expectEqual(@as(u8, 1), client.model.notificationSnapshot().count);
    try std.testing.expectEqualStrings(
        "TLS interception active",
        client.model.notificationSnapshot().itemAt(0).?.title(),
    );

    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(enabled));

    try std.testing.expectEqual(version_before.proxy_status + 1, client.model.version().proxy_status);
    try std.testing.expectEqual(version_before.notifications + 1, client.model.version().notifications);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    try std.testing.expectEqual(@as(u8, 1), client.model.notificationSnapshot().count);

    try presentation_lifecycle.observe(client);
    const enabled_version = client.model.version();

    try std.testing.expectEqual(pending_updates_before + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
    try std.testing.expectEqual(
        enabled_version.proxy_status,
        client.presenter.presented_model_version.proxy_status,
    );
    const badge_index = @as(usize, client.presenter.screen.front.w) - 2;
    try std.testing.expectEqualStrings("\u{26e8}", client.presenter.screen.front.cells[badge_index].text());

    const pending_updates_after_enabled = client.presenter.pending_updates;
    const version_before_disabled = client.model.version();
    const disabled = try schema.encodeProxyStatus(&payload, .{ .active = false });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(disabled));

    try std.testing.expect(!client.model.proxyTlsActive());
    try std.testing.expectEqual(version_before_disabled.proxy_status + 1, client.model.version().proxy_status);
    try std.testing.expectEqual(version_before_disabled.notifications + 1, client.model.version().notifications);
    try std.testing.expectEqual(pending_updates_after_enabled, client.presenter.pending_updates);
    try std.testing.expectEqual(@as(u8, 2), client.model.notificationSnapshot().count);
    try std.testing.expectEqualStrings(
        "TLS interception stopped",
        client.model.notificationSnapshot().itemAt(0).?.title(),
    );

    try presentation_lifecycle.observe(client);
    const disabled_version = client.model.version();
    try harness.settleModelPresentation();

    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
    try std.testing.expectEqual(
        disabled_version.proxy_status,
        client.presenter.presented_model_version.proxy_status,
    );
    try std.testing.expect(!std.mem.eql(u8, "\u{26e8}", client.presenter.screen.front.cells[badge_index].text()));
}

test "system metrics commit before presenter-owned projection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;

    var payload: [64]u8 = undefined;
    const metrics = try schema.encodeSystemMetrics(&payload, .{
        .revision = 7,
        .cpu_percent = 50,
        .memory_used_decigib = 10,
        .has_battery = true,
        .battery_percent = 80,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(metrics));

    try std.testing.expectEqualDeep(client_model.SystemMetrics{
        .runtime_revision = 7,
        .cpu_percent = 50,
        .memory_used_decigib = 10,
        .battery_percent = 80,
    }, client.model.systemMetrics().?);
    try std.testing.expectEqual(version_before.system_metrics + 1, client.model.version().system_metrics);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    try std.testing.expect(!client.view.dirty);

    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(metrics));
    try std.testing.expectEqual(version_before.system_metrics + 1, client.model.version().system_metrics);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);

    const status = client.view.regions.status;
    var status_text_buffer: [512]u8 = undefined;
    var status_text_len: usize = 0;
    for (status.x..status.x + status.w) |x| {
        const cell = client.presenter.screen.front.cells[@as(usize, status.y) * client.presenter.screen.front.w + x];
        const text = cell.text();
        @memcpy(status_text_buffer[status_text_len..][0..text.len], text);
        status_text_len += text.len;
    }
    const status_text = status_text_buffer[0..status_text_len];

    try std.testing.expect(std.mem.indexOf(u8, status_text, " 50%") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_text, " 1.0G") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_text, "80%") != null);
}

test "workspace list snapshots commit before presenter-owned projection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;

    var payload: [512]u8 = undefined;
    const list = try schema.encodeWorkspaceList(&payload, .{
        .revision = 7,
        .entries = &.{
            .{ .workspace = @enumFromInt(1), .name = "main", .path = "/work/main", .tab_count = 1 },
            .{ .workspace = @enumFromInt(2), .name = "api", .path = "/work/api", .tab_count = 2 },
        },
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(list));

    try std.testing.expect(client.model.knowsWorkspace(@enumFromInt(1)));
    try std.testing.expect(client.model.knowsWorkspace(@enumFromInt(2)));
    try std.testing.expectEqualStrings("/work/api", client.model.workspaceListSnapshot().pathAt(1));
    try std.testing.expectEqual(version_before.workspace_list + 1, client.model.version().workspace_list);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    try std.testing.expect(!client.view.dirty);

    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(list));
    try std.testing.expectEqual(version_before.workspace_list + 1, client.model.version().workspace_list);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
    var found_second = false;
    for (0..client.presenter.screen.front.w) |x| {
        const action = client.view.hits.at(@intCast(x), 0) orelse continue;
        if (action == .select_workspace and action.select_workspace == @as(schema.WorkspaceId, @enumFromInt(2))) {
            found_second = true;
            break;
        }
    }
    try std.testing.expect(found_second);
}

test "workspace position navigation resolves the committed client model" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};

    var payload: [512]u8 = undefined;
    const list = try schema.encodeWorkspaceList(&payload, .{
        .revision = 1,
        .entries = &.{
            .{ .workspace = @enumFromInt(1), .name = "main", .path = "/work/main", .tab_count = 1 },
            .{ .workspace = @enumFromInt(2), .name = "api", .path = "/work/api", .tab_count = 1 },
        },
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(list));
    const pending_updates_before = client.presenter.pending_updates;
    const handler: InputHandler = .{ .client = client };

    _ = try client_actions.apply(handler.client, .{ .select_workspace = 1 });

    try std.testing.expect(client.model.workspaceLocation() == null);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    try std.testing.expect(!handler.redraw);
    try harness.settle();

    var message_buffer: [256]u8 = undefined;
    var target: ?schema.PaneTarget = null;
    while (target == null) {
        switch (try harness.nextClientMessage(&message_buffer)) {
            .detach_pane => {},
            .open_pane => |open| target = open.target,
            else => return error.UnexpectedClientMessage,
        }
    }

    try std.testing.expectEqualDeep(
        schema.PaneTarget{ .workspace = @enumFromInt(2) },
        target.?,
    );
}

test "an agent snapshot replaces the sidebar replica" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();

    var payload: [512]u8 = undefined;
    const snapshot = try schema.encodeAgentSnapshot(&payload, .{
        .revision = 1,
        .entries = &.{.{
            .pane_id = TestHarness.bootstrap_pane,
            .pane_generation = 1,
            .location = TestHarness.bootstrap_location,
            .pane_index = 1,
            .process_id = 42,
            .session_id = @splat(0),
            .workspace_label = "telar",
            .tab_label = "test-2",
            .session_title = "Improve agent sidebar",
            .title_source = .generated,
            .title_state = .ready,
            .cwd_label = "~/sandbox/telar",
            .provider = .claude,
            .status = .working,
            .source = .screen,
            .authority = .active,
            .confidence = 1,
            .sequence = 1,
            .observed_at_ms = 1,
            .expires_at_ms = 2,
        }},
    });
    const pending_updates = harness.client.presenter.pending_updates;
    harness.client.view.sidebar.scroll = 7;
    _ = try server_messages.handleServerMessage(harness.client, try schema.decodeServer(snapshot));
    const agent = harness.client.model.agentSnapshot().find(.{
        .pane_id = TestHarness.bootstrap_pane,
        .pane_generation = 1,
    }).?;
    try std.testing.expectEqualStrings("telar", agent.workspaceLabel());
    try std.testing.expectEqualStrings("test-2", agent.tabLabel());
    try std.testing.expectEqualStrings("Improve agent sidebar", agent.sessionTitle());
    try std.testing.expectEqualStrings("~/sandbox/telar", agent.cwdLabel());
    try std.testing.expectEqual(client_model.Version{ .agents = 1 }, harness.client.model.version());
    try std.testing.expectEqual(pending_updates, harness.client.presenter.pending_updates);

    try presentation_lifecycle.observe(harness.client);
    try harness.settleModelPresentation();

    try std.testing.expectEqual(@as(u16, 0), harness.client.view.sidebar.scroll);
    try std.testing.expectEqual(
        harness.client.model.version(),
        harness.client.presenter.presented_model_version,
    );
}

test "sidebar animation commits model state before the presenter observes it" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    var payload: [512]u8 = undefined;
    const snapshot = try encodeTestingAgentSnapshot(&payload, 1, .working);
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(snapshot));
    const pending_updates = client.presenter.pending_updates;

    try std.testing.expect(client.sidebar_animation_scheduler.pending);
    try std.testing.expectEqual(@as(u8, 0), client.model.sidebarAnimationFrame());
    switch (try client.select.await()) {
        .sidebar_animation_tick => |result| {
            const change = (try sidebar_animations.handleTick(client, result)).?;

            try std.testing.expectEqual(@as(u8, 1), change.frame);
            try std.testing.expectEqual(@as(u64, 1), change.sidebar_animation_revision);
        },
        else => return error.UnexpectedEvent,
    }

    try std.testing.expect(client.sidebar_animation_scheduler.pending);
    try std.testing.expectEqual(client_model.Version{
        .agents = 1,
        .sidebar_animation = 1,
    }, client.model.version());
    try std.testing.expectEqual(@as(u8, 1), client.model.sidebarAnimationFrame());
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates + 1, client.presenter.pending_updates);
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.observed_model_version);
}

test "agent snapshot transitions raise bounded presentation alerts only once" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    var payload: [512]u8 = undefined;

    const initial = try encodeTestingAgentSnapshot(&payload, 1, .ready);
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(initial));

    try std.testing.expectEqual(@as(u8, 0), client.model.notificationSnapshot().count);
    try std.testing.expectEqual(client_model.Version{ .agents = 1 }, client.model.version());

    const changed = try encodeTestingAgentSnapshot(&payload, 2, .blocked);
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(changed));
    const notification = client.model.notificationSnapshot().itemAt(0).?;

    try std.testing.expectEqual(client_model.Version{ .agents = 2, .notifications = 1 }, client.model.version());
    try std.testing.expectEqual(@as(u8, 1), client.model.notificationSnapshot().count);
    try std.testing.expectEqual(notifications.Level.warning, notification.level);
    try std.testing.expectEqualStrings("Agent needs input", notification.title());
    try std.testing.expectEqualStrings("Claude in pane 3 is waiting for input", notification.message());
    try std.testing.expectEqualDeep(
        notifications.Target{ .focus_pane = TestHarness.bootstrap_pane },
        notification.target,
    );

    const stale = try encodeTestingAgentSnapshot(&payload, 1, .failed);
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(stale));

    try std.testing.expectEqual(client_model.Version{ .agents = 2, .notifications = 1 }, client.model.version());
    try std.testing.expectEqual(@as(u8, 1), client.model.notificationSnapshot().count);
}

test "agent sounds validate exact identity against the client model" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    var payload: [512]u8 = undefined;
    const snapshot = try encodeTestingAgentSnapshot(&payload, 1, .ready);
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(snapshot));
    const version_before_sound = client.model.version();
    const pending_updates = client.presenter.pending_updates;

    const unknown = try schema.encodeAgentSound(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .pane_generation = 2,
        .sound = .ready,
    });
    const stale = try agent_sounds.apply(client, (try schema.decodeServer(unknown)).agent_sound);

    try std.testing.expectEqual(agent_sounds.Outcome.stale, stale);
    try std.testing.expect(!client.sound_playback.snapshot().active);

    const known = try schema.encodeAgentSound(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .pane_generation = 1,
        .sound = .ready,
    });
    const accepted = try agent_sounds.apply(client, (try schema.decodeServer(known)).agent_sound);

    try std.testing.expectEqual(agent_sounds.Outcome.accepted, accepted);
    try std.testing.expect(client.sound_playback.snapshot().active);

    const urgent = try schema.encodeAgentSound(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .pane_generation = 1,
        .sound = .needs_input,
    });
    const queued = try agent_sounds.apply(client, (try schema.decodeServer(urgent)).agent_sound);

    try std.testing.expectEqual(agent_sounds.Outcome.accepted, queued);
    try std.testing.expectEqual(schema.AgentSound.needs_input, client.sound_playback.snapshot().queued.?);
    try std.testing.expectEqualDeep(version_before_sound, client.model.version());
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);
}

test "agent sound completion releases a failed worker before scheduling its successor" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const version_before = client.model.version();
    const pending_updates = client.presenter.pending_updates;

    try std.testing.expectEqualDeep(
        sound_capability.RequestOutcome{ .start = .ready },
        client.sound_playback.request(.ready),
    );
    try std.testing.expect(client.sound_playback.request(.needs_input) == .queued);

    try agent_sounds.handlePlayed(client, error.SoundUnavailable);

    try std.testing.expectEqual(sound_capability.Snapshot{
        .configuration = .{},
        .active = true,
        .queued = null,
    }, client.sound_playback.snapshot());
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);
}

test "a graphics revision break requests a graphics snapshot" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;

    var payload: [256]u8 = undefined;
    const begin = try schema.encodeGraphicsSnapshot(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .revision = 8,
        .phase = .begin,
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(begin));
    const image = try schema.encodeGraphicsImage(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .revision = 9,
        .image = .{
            .key = .{ .image_id = 1, .generation = 1 },
            .format = .rgb,
            .width = 1,
            .height = 1,
            .byte_len = 3,
        },
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(image));
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .request_graphics_snapshot);
}

test "pane graphics commit their cell fallback before presenter observation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    _ = try client.model.observeHostCapability(.{ .kitty_graphics = .unsupported });
    const version_before = client.model.version();
    const pending_before = client.presenter.pending_updates;

    var payload: [256]u8 = undefined;
    const encoded = try schema.encodeGraphicsImage(&payload, .{
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
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(encoded));

    var committed = version_before;
    committed.pane_graphics += 1;
    try std.testing.expectEqualDeep(committed, client.model.version());
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.graphics_placeholder);
    try std.testing.expectEqual(pending_before, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_before + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(committed, client.presenter.presented_model_version);
}

test "presenter observes physical graphics without a semantic fallback" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    _ = try client.model.observeHostCapability(.{ .kitty_graphics = .supported });
    const version_before = client.model.version();
    const pending_before = client.presenter.pending_updates;

    var payload: [256]u8 = undefined;
    const encoded = try schema.encodeGraphicsImage(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .revision = 5,
        .image = .{
            .key = .{ .image_id = 1, .generation = 1 },
            .format = .rgb,
            .width = 1,
            .height = 1,
            .byte_len = 3,
        },
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(encoded));

    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(@as(u64, 1), client.graphics_store.ingressVersion());
    try std.testing.expectEqual(pending_before, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_before + 1, client.presenter.pending_updates);
    try std.testing.expectEqual(@as(u64, 1), client.presenter.observed_graphics_ingress);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(@as(u64, 1), client.presenter.presented_graphics_ingress);

    const pending_after = client.presenter.pending_updates;
    const stale = try schema.encodeGraphicsDeleteImage(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .revision = 4,
        .key = .{ .image_id = 1, .generation = 1 },
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(stale));
    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(@as(u64, 1), client.graphics_store.ingressVersion());
    try std.testing.expectEqual(pending_after, client.presenter.pending_updates);
}

test "shared graphics mapping failure downgrades before resynchronizing" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before = client.model.version();

    var payload: [256]u8 = undefined;
    const encoded = try schema.encodeGraphicsSharedImage(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .revision = 1,
        .image = .{
            .key = .{ .image_id = 1, .generation = 1 },
            .format = .rgb,
            .width = 1,
            .height = 1,
            .byte_len = 3,
        },
        .name = try core.graphics.ShmName.init("/telar-missing"),
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(encoded));
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const downgrade = try harness.nextClientMessage(&buffer);
    const recovery = try harness.nextClientMessage(&buffer);
    try std.testing.expect(downgrade == .configure_graphics);
    try std.testing.expect(!downgrade.configure_graphics.shared);
    try std.testing.expect(recovery == .request_graphics_snapshot);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, recovery.request_graphics_snapshot.pane_id);
    try std.testing.expectEqual(@as(u64, 0), client.graphics_store.ingressVersion());
    try std.testing.expectEqualDeep(version_before, client.model.version());
}

test "runtime stopping and stray history results" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();

    var payload: [128]u8 = undefined;
    const stopping = try schema.encodeRuntimeStopping(&payload);
    try std.testing.expectEqual(
        @as(?u8, 0),
        try server_messages.handleServerMessage(harness.client, try schema.decodeServer(stopping)),
    );

    const history = try schema.encodeHistoryResults(&payload, .{
        .request_id = @enumFromInt(2),
        .entries = &.{},
    });
    try std.testing.expectError(
        error.UnexpectedHistoryResults,
        server_messages.handleServerMessage(harness.client, try schema.decodeServer(history)),
    );
}

test "a pane clipboard write reaches the host terminal" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();

    const before = harness.sink.fullCount();
    var payload: [128]u8 = undefined;
    const clipboard = try schema.encodePaneClipboard(&payload, .{
        .pane_id = TestHarness.bootstrap_pane,
        .bytes = "copied",
    });
    _ = try server_messages.handleServerMessage(harness.client, try schema.decodeServer(clipboard));

    try std.testing.expectEqual(
        @as(u64, "\x1b]52;c;Y29waWVk\x07".len),
        harness.sink.fullCount() - before,
    );
}

test "an invalid pane clipboard writes no host bytes" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const before = harness.sink.fullCount();

    try std.testing.expectError(error.UnexpectedPane, pane_clipboards.apply(harness.client, .{
        .pane_id = .invalid,
        .bytes = "rejected",
    }));

    try std.testing.expectEqual(before, harness.sink.fullCount());
}

test "config reload outcomes that carry no new generation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;

    try std.testing.expectEqual(
        config_reloads.Outcome.unchanged,
        try config_reloads.handle(client, .{ .unchanged = 42 }),
    );
    try std.testing.expectEqual(@as(i128, 42), client.reload.mtime_ns);

    var diagnostic: lua_config.Diagnostic = .{};
    diagnostic.set("bad config: {s}", .{"boom"});
    try std.testing.expectEqual(
        config_reloads.Outcome.rejected,
        try config_reloads.handle(client, .{ .failed = .{
            .diagnostic = diagnostic,
            .mtime_ns = 7,
        } }),
    );
    try std.testing.expectEqual(@as(i128, 7), client.reload.mtime_ns);
    try std.testing.expect(client.notification_scheduler.pending);
    try std.testing.expect(client.model.diagnostic() != null);
    try harness.settle();
}

test "configuration adoption swaps ownership after commit and presents by version" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const initial = try testingConfigAdoption(1, false);
    const initial_generation = initial.generation;

    const first = try config_reloads.apply(client, initial);

    try std.testing.expectEqual(@as(u64, 1), first.generation);
    try std.testing.expect(client.lua_generation == initial_generation);
    try std.testing.expectEqual(@as(u64, 1), client.model.configurationGeneration());

    try std.testing.expectEqualDeep(
        sound_capability.RequestOutcome{ .start = .ready },
        client.sound_playback.request(.ready),
    );
    try std.testing.expect(client.sound_playback.request(.ready) == .queued);
    const pending_updates = client.presenter.pending_updates;
    const changed = try testingConfigAdoption(2, true);
    const changed_generation = changed.generation;
    const second = try config_reloads.apply(client, changed);

    try std.testing.expectEqual(@as(u64, 2), second.generation);
    try std.testing.expectEqual(@as(u64, 2), second.configuration_revision);
    try std.testing.expect(!second.sidebar.?.visible);
    try std.testing.expect(second.pane_gaps_changed);
    try std.testing.expect(client.lua_generation == changed_generation);
    try std.testing.expectEqual(@as(u64, 2), client.model.configurationGeneration());
    try std.testing.expect(!client.model.sidebarVisible());
    try std.testing.expect(!client.model.paneGaps());
    try std.testing.expect(!client.view.sidebar_requested);
    try std.testing.expectEqualDeep(try keybind.parseKey("ctrl+s"), client.host_input.router.prefix.?);
    try std.testing.expectEqual(
        @as(u64, 40 * std.time.ns_per_ms),
        client.host_input.router.escape_timeout_ns,
    );
    try std.testing.expectEqual(
        @as(u64, 750 * std.time.ns_per_ms),
        client.host_input.router.sequence_timeout_ns,
    );
    try std.testing.expectEqual(sound_capability.Snapshot{
        .configuration = .{ .enabled = false },
        .active = true,
        .queued = null,
    }, client.sound_playback.snapshot());
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();

    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
    try std.testing.expectEqual(client_model.Version{
        .configuration = 2,
        .notifications = 2,
        .panes = 1,
        .chrome = 1,
    }, client.model.version());

    const stale = try testingConfigAdoption(2, false);
    try std.testing.expectError(error.StaleConfiguration, config_reloads.apply(client, stale));
    try std.testing.expect(client.lua_generation == changed_generation);
    try std.testing.expectEqual(@as(u64, 2), client.model.configurationGeneration());
}

test "configuration adoption keeps new ownership after geometry failure" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    while (client.runtime_transport.outbox.hasCapacity()) {
        try client.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }
    const adoption = try testingConfigAdoption(1, true);
    const generation = adoption.generation;

    try std.testing.expectError(error.ClientOutboxFull, config_reloads.apply(client, adoption));

    try std.testing.expect(client.lua_generation == generation);
    try std.testing.expectEqual(@as(u64, 1), client.model.configurationGeneration());
    try std.testing.expectEqual(@as(u64, 1), client.model.version().configuration);
    try std.testing.expect(!client.model.sidebarVisible());
    try std.testing.expect(!client.model.paneGaps());
    try std.testing.expect(!client.view.sidebar_requested);
    try std.testing.expectEqual(@as(usize, client_outbox.capacity), client.runtime_transport.outbox.len);
}

test "a configuration version alone schedules presenter observation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const pending_updates = client.presenter.pending_updates;

    _ = try client.model.applyConfiguration(.{
        .generation = 1,
        .sidebar_visible = true,
        .pane_gaps = true,
    });

    try std.testing.expectEqual(client_model.Version{ .configuration = 1 }, client.model.version());
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();

    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
}

test "plugin completion applies one authorized batch through model observation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const installed = try installTestingPlugin(client);
    const execution = (try client.model.beginPluginExecution()).?;
    var batch: lua_config.EffectBatch = .{};
    batch.items[0] = .toggle_workspace_list;
    batch.len = 1;
    const version_before = client.model.version();
    const pending_before = client.presenter.pending_updates;

    const exit = try client.handlePluginResultEvent(.{
        .execution_id = execution.id,
        .result = plugin_broker.WorkerResult{
            .package_index = 0,
            .plugin_id = installed.action.plugin,
            .digest = installed.digest,
            .batch = batch,
        },
    });

    try std.testing.expect(!exit);
    try std.testing.expect(client.model.pluginExecution() == null);
    try std.testing.expect(client.model.workspaceListCollapsed());
    try std.testing.expectEqual(version_before.chrome + 1, client.model.version().chrome);
    try std.testing.expectEqual(pending_before, client.presenter.pending_updates);
    try std.testing.expect(!client.view.workspace_list_collapsed);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_before + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expect(client.view.workspace_list_collapsed);
}

test "plugin completion from an old configuration is consumed without effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const installed = try installTestingPlugin(client);
    const execution = (try client.model.beginPluginExecution()).?;
    var batch: lua_config.EffectBatch = .{};
    batch.items[0] = .toggle_workspace_list;
    batch.len = 1;

    _ = try client.model.applyConfiguration(.{
        .generation = 1,
        .sidebar_visible = true,
        .pane_gaps = true,
    });
    const version_after_reload = client.model.version();
    const pending_before = client.presenter.pending_updates;

    const exit = try client.handlePluginResultEvent(.{
        .execution_id = execution.id,
        .result = plugin_broker.WorkerResult{
            .package_index = 0,
            .plugin_id = installed.action.plugin,
            .digest = installed.digest,
            .batch = batch,
        },
    });

    try std.testing.expect(!exit);
    try std.testing.expect(client.model.pluginExecution() == null);
    try std.testing.expect(!client.model.workspaceListCollapsed());
    try std.testing.expectEqualDeep(version_after_reload, client.model.version());
    try std.testing.expect(client.model.diagnostic() == null);
    try std.testing.expectEqual(pending_before, client.presenter.pending_updates);
}

test "plugin authorization denial consumes the run before publishing failure" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const installed = try installTestingPlugin(client);
    const execution = (try client.model.beginPluginExecution()).?;
    var batch: lua_config.EffectBatch = .{};
    batch.items[0] = .close_pane;
    batch.len = 1;
    const version_before = client.model.version();
    const pending_before = client.presenter.pending_updates;

    const exit = try client.handlePluginResultEvent(.{
        .execution_id = execution.id,
        .result = plugin_broker.WorkerResult{
            .package_index = 0,
            .plugin_id = installed.action.plugin,
            .digest = installed.digest,
            .batch = batch,
        },
    });

    try std.testing.expect(!exit);
    try std.testing.expect(client.model.pluginExecution() == null);
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane) != null);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expect(client.model.version().notifications > version_before.notifications);
    try std.testing.expect(std.mem.indexOf(
        u8,
        client.model.diagnostic().?,
        "CapabilityNotGranted",
    ) != null);
    try std.testing.expect(client.notification_scheduler.pending);
    try std.testing.expectEqual(pending_before, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_before + 1, client.presenter.pending_updates);
}

test "plugin worker failure and unmatched completion preserve lifecycle identity" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const execution = (try client.model.beginPluginExecution()).?;

    try std.testing.expect(!try client.handlePluginResultEvent(.{
        .execution_id = @enumFromInt(@intFromEnum(execution.id) + 1),
        .result = error.TestPluginWorkerFailure,
    }));
    try std.testing.expectEqualDeep(execution, client.model.pluginExecution().?);
    try std.testing.expect(client.model.diagnostic() == null);

    try std.testing.expect(!try client.handlePluginResultEvent(.{
        .execution_id = execution.id,
        .result = error.TestPluginWorkerFailure,
    }));
    try std.testing.expect(client.model.pluginExecution() == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        client.model.diagnostic().?,
        "TestPluginWorkerFailure",
    ) != null);
    try std.testing.expect(client.notification_scheduler.pending);
}

test "busy plugin start skips resolution and a rejected action leaves no run" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const installed = try installTestingPlugin(client);
    const execution = (try client.model.beginPluginExecution()).?;

    const busy = try plugin_actions.start(client, installed.action, testing_plugin_context);

    try std.testing.expect(busy == .busy);
    try std.testing.expectEqualDeep(execution, client.model.pluginExecution().?);
    _ = client.model.finishPluginExecution(execution.id);

    const rejected = try plugin_actions.start(client, .{
        .plugin = installed.action.plugin,
        .action = core.plugin.stableId("missing"),
    }, testing_plugin_context);

    try std.testing.expect(rejected == .rejected);
    try std.testing.expect(client.model.pluginExecution() == null);
    try std.testing.expect(client.notification_scheduler.pending);
    try std.testing.expect(std.mem.indexOf(
        u8,
        client.model.diagnostic().?,
        "UnknownPluginAction",
    ) != null);
}

test "Lua callback applies a validated batch through model observation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const configured = try installTestingLuaBinding(client,
        \\local telar = require("telar")
        \\return {
        \\  api_version = 2,
        \\  client = { keybindings = {
        \\    telar.bind({ "x" }, function(ctx)
        \\      if ctx.tab_count ~= 1 or ctx.pane_count ~= 1 or ctx.focused_pane_id ~= 10 then
        \\        error("bad callback context")
        \\      end
        \\      return telar.action.toggle_workspace_list()
        \\    end),
        \\  } },
        \\}
    );
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    _ = try client.model.setDiagnostic("old diagnostic", .{});
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    const version_before = client.model.version();
    const pending_before = client.presenter.pending_updates;
    var handler: InputHandler = .{ .client = client };

    const control = try handler.action(configured);

    try std.testing.expect(control == .continue_routing);
    try std.testing.expect(client.model.workspaceListCollapsed());
    try std.testing.expect(client.model.diagnostic() == null);
    var expected = version_before;
    expected.chrome += 1;
    expected.diagnostic += 1;
    try std.testing.expectEqualDeep(expected, client.model.version());
    try std.testing.expect(!handler.redraw);
    try std.testing.expectEqual(pending_before, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_before + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expect(client.view.workspace_list_collapsed);
    try std.testing.expectEqual(expected.diagnostic, client.presenter.presented_model_version.diagnostic);
}

test "Lua callback validates every plugin reference before native effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const configured = try installTestingLuaBinding(client,
        \\local telar = require("telar")
        \\return {
        \\  api_version = 2,
        \\  client = { keybindings = {
        \\    telar.bind({ "x" }, function(ctx)
        \\      return {
        \\        telar.action.toggle_sidebar(),
        \\        telar.action.plugin({ plugin = "missing.plugin", action = "run" }),
        \\      }
        \\    end),
        \\  } },
        \\}
    );
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    const version_before = client.model.version();
    const pending_before = client.presenter.pending_updates;
    var handler: InputHandler = .{ .client = client };

    const control = try handler.action(configured);

    try std.testing.expect(control == .continue_routing);
    try std.testing.expect(client.model.sidebarVisible());
    try std.testing.expect(std.mem.indexOf(
        u8,
        client.model.diagnostic().?,
        "PluginNotConfigured",
    ) != null);
    var expected = version_before;
    expected.diagnostic += 1;
    try std.testing.expectEqualDeep(expected, client.model.version());
    try std.testing.expect(!handler.redraw);
    try std.testing.expectEqual(pending_before, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_before + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expect(client.view.sidebar_requested);
}

test "Lua expression emits semantic keys through pane input" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const configured = try installTestingLuaBinding(client,
        \\local telar = require("telar")
        \\return {
        \\  api_version = 2,
        \\  client = { keybindings = {
        \\    telar.bind_expr({ "x" }, function(ctx)
        \\      return telar.input.keys({ "left", "enter" })
        \\    end),
        \\  } },
        \\}
    );
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    const version_before = client.model.version();
    const pending_before = client.presenter.pending_updates;
    var handler: InputHandler = .{ .client = client };

    const control = try handler.action(configured);

    try std.testing.expect(control == .continue_routing);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_before, client.presenter.pending_updates);
    try std.testing.expect(!handler.redraw);
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const left = try harness.nextClientMessage(&buffer);
    try std.testing.expect(left == .pane_input);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, left.pane_input.pane_id);
    try std.testing.expectEqualStrings("\x1b[D", left.pane_input.bytes);
    const enter = try harness.nextClientMessage(&buffer);
    try std.testing.expect(enter == .pane_input);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, enter.pane_input.pane_id);
    try std.testing.expectEqualStrings("\r", enter.pane_input.bytes);
}

test "Lua callback failure commits one diagnostic without direct presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const configured = try installTestingLuaBinding(client,
        \\local telar = require("telar")
        \\return {
        \\  api_version = 2,
        \\  client = { keybindings = {
        \\    telar.bind({ "x" }, function(ctx)
        \\      error("callback exploded")
        \\    end),
        \\  } },
        \\}
    );
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    const version_before = client.model.version();
    const pending_before = client.presenter.pending_updates;
    var handler: InputHandler = .{ .client = client };

    const control = try handler.action(configured);

    try std.testing.expect(control == .continue_routing);
    try std.testing.expect(std.mem.indexOf(
        u8,
        client.model.diagnostic().?,
        "callback exploded",
    ) != null);
    var expected = version_before;
    expected.diagnostic += 1;
    try std.testing.expectEqualDeep(expected, client.model.version());
    try std.testing.expect(!handler.redraw);
    try std.testing.expectEqual(pending_before, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_before + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(expected.diagnostic, client.presenter.presented_model_version.diagnostic);
}

test "control-v reaches the pane when no clipboard preview target exists" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    var handler: InputHandler = .{ .client = client };

    try handler.key(try keybind.parseKey("ctrl+v"));

    try std.testing.expect(client.model.clipboardCapture() == null);
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .pane_input);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, message.pane_input.pane_id);
    try std.testing.expectEqualStrings("\x16", message.pane_input.bytes);
}

test "clipboard image completion publishes resource ingress before presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const target = try installTestingAttachmentTarget(client, 1);
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    const execution = (try client.model.beginClipboardCapture(target)).?;
    const completed = try testingClipboardCapture(client, execution, "png");
    const version_before = client.model.version();
    const pending_before = client.presenter.pending_updates;

    try client.handleClipboardImageEvent(.{
        .execution_id = execution.id,
        .result = completed,
    });

    try std.testing.expect(client.model.clipboardCapture() == null);
    try std.testing.expect(client.clipboard_capture_resources.orphan == null);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(@as(u64, 1), client.view.kittyAttachments().ingressVersion());
    try std.testing.expectEqual(@as(u8, 1), client.view.kittyAttachments().snapshot().len);
    try std.testing.expectEqual(pending_before, client.presenter.pending_updates);
    try std.testing.expectEqual(@as(u64, 0), client.presenter.observed_attachment_ingress);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_before + 1, client.presenter.pending_updates);
    try std.testing.expectEqual(@as(u64, 1), client.presenter.observed_attachment_ingress);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(@as(u64, 1), client.presenter.presented_attachment_ingress);
}

test "clipboard image from a retired agent target is consumed and freed" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const target = try installTestingAttachmentTarget(client, 1);
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    const execution = (try client.model.beginClipboardCapture(target)).?;
    const completed = try testingClipboardCapture(client, execution, "private png");

    _ = try client.model.reconcileAgentSnapshot(.{ .revision = 2, .agents = &.{} });
    _ = try attachment_targets.sync(client);
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    const version_before = client.model.version();
    const pending_before = client.presenter.pending_updates;

    try client.handleClipboardImageEvent(.{
        .execution_id = execution.id,
        .result = completed,
    });

    try std.testing.expect(client.model.clipboardCapture() == null);
    try std.testing.expect(client.clipboard_capture_resources.orphan == null);
    try std.testing.expectEqual(@as(u64, 0), client.view.kittyAttachments().ingressVersion());
    try std.testing.expectEqual(@as(u8, 0), client.view.kittyAttachments().snapshot().len);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_before, client.presenter.pending_updates);
}

test "clipboard image failures settle lifecycle without direct presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const target = try installTestingAttachmentTarget(client, 1);
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    const pending_before = client.presenter.pending_updates;
    const no_image = (try client.model.beginClipboardCapture(target)).?;
    const version_before_empty = client.model.version();

    try client.handleClipboardImageEvent(.{
        .execution_id = no_image.id,
        .result = error.NoImageOnClipboard,
    });

    try std.testing.expect(client.model.clipboardCapture() == null);
    try std.testing.expectEqualDeep(version_before_empty, client.model.version());
    try std.testing.expectEqual(pending_before, client.presenter.pending_updates);

    const too_large = (try client.model.beginClipboardCapture(target)).?;
    const version_before_large = client.model.version();
    try client.handleClipboardImageEvent(.{
        .execution_id = too_large.id,
        .result = error.ClipboardImageTooLarge,
    });

    try std.testing.expect(client.model.clipboardCapture() == null);
    try std.testing.expect(client.model.version().notifications > version_before_large.notifications);
    try std.testing.expect(client.notification_scheduler.pending);
    try std.testing.expectEqual(pending_before, client.presenter.pending_updates);

    const invalid = (try client.model.beginClipboardCapture(target)).?;
    const completed = try testingClipboardCapture(client, invalid, "invalid");
    completed.width = 0;
    const version_before_invalid = client.model.version();
    try client.handleClipboardImageEvent(.{
        .execution_id = invalid.id,
        .result = completed,
    });

    try std.testing.expect(client.model.clipboardCapture() == null);
    try std.testing.expect(client.clipboard_capture_resources.orphan == null);
    try std.testing.expect(client.model.version().notifications > version_before_invalid.notifications);
    try std.testing.expectEqual(@as(u64, 0), client.view.kittyAttachments().ingressVersion());
    try std.testing.expectEqual(pending_before, client.presenter.pending_updates);
}

test "host resize commits before resources and presents by model version" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const pending_updates = client.presenter.pending_updates;
    const measurement: platform.Size = .{
        .cols = 100,
        .rows = 30,
        .width_px = 1000,
        .height_px = 600,
    };

    const commit = (try host_resizes.apply(client, measurement)).?.resize.?;

    const expected: schema.TerminalSize = .{
        .cols = 100,
        .rows = 30,
        .cell_width_px = 10,
        .cell_height_px = 20,
    };
    try std.testing.expectEqualDeep(expected, commit.current);
    try std.testing.expectEqualDeep(expected, client.model.hostSize());
    try std.testing.expectEqual(client_model.Version{
        .host = 1,
        .host_capabilities = 1,
        .workspace = 1,
        .tabs = 1,
        .active_tab = 1,
        .panes = 1,
    }, client.model.version());
    try std.testing.expect(client.presenter.screen.sizeMatches(100, 30));
    try std.testing.expectEqual(@as(u16, 100), client.view.scratch.w);
    try std.testing.expectEqual(@as(u16, 30), client.view.scratch.h);
    const active = client.model.workspace.active().?;
    try std.testing.expectEqual(@as(u16, 10), active.model.cell_width_px);
    try std.testing.expectEqual(@as(u16, 20), active.model.cell_height_px);
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);

    const expected_pane_size = active.model.contentSize(
        TestHarness.bootstrap_pane,
        client.view.workbench(),
    ).?;
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .pane_resize);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, message.pane_resize.pane_id);
    try std.testing.expectEqualDeep(expected_pane_size, message.pane_resize.size);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);

    const version = client.model.version();
    const pending_after = client.presenter.pending_updates;
    try std.testing.expect((try host_resizes.apply(client, measurement)) == null);
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try std.testing.expectEqual(pending_after, client.presenter.pending_updates);
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
    const pending_updates = client.presenter.pending_updates;
    const measurement: platform.Size = .{
        .cols = 90,
        .rows = 28,
        .width_px = 900,
        .height_px = 560,
    };

    try std.testing.expectError(error.ClientOutboxFull, host_resizes.apply(client, measurement));

    try std.testing.expectEqual(schema.TerminalSize{
        .cols = 90,
        .rows = 28,
        .cell_width_px = 10,
        .cell_height_px = 20,
    }, client.model.hostSize());
    try std.testing.expectEqual(@as(u64, 1), client.model.version().host);
    try std.testing.expectEqual(@as(u64, 1), client.model.version().host_capabilities);
    try std.testing.expect(client.presenter.screen.sizeMatches(90, 28));
    try std.testing.expectEqual(@as(u16, 90), client.view.scratch.w);
    try std.testing.expectEqual(@as(u16, 28), client.view.scratch.h);
    try std.testing.expectEqual(@as(usize, client_outbox.capacity), client.runtime_transport.outbox.len);
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);
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
    try std.testing.expectEqualDeep(client_model.Version{}, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "terminal pixel response keeps model host geometry authoritative" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const pending_updates = client.presenter.pending_updates;
    var handler: InputHandler = .{ .client = client };

    try handler.terminalResponse(.{ .cell_pixels = .{
        .width = 12,
        .height = 24,
    } });

    try std.testing.expect(!handler.redraw);
    try std.testing.expectEqual(schema.TerminalSize{
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
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates + 1, client.presenter.pending_updates);
}

test "input timer expiries with nothing pending are a no-op" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();

    try std.testing.expect(!try host_inputs.handleInputTimeout(harness.client, {}));
    try std.testing.expect(!try host_inputs.handleBindingTimeout(harness.client, {}));
    try std.testing.expect(!harness.client.host_input.input_timeout.pending);
    try std.testing.expect(!harness.client.host_input.binding_timeout.pending);

    harness.client.host_input.input_timeout.pending = true;
    try std.testing.expectError(
        error.InputTimerFailed,
        host_inputs.handleInputTimeout(harness.client, error.InputTimerFailed),
    );
    try std.testing.expect(!harness.client.host_input.input_timeout.pending);

    harness.client.host_input.binding_timeout.pending = true;
    try std.testing.expectError(
        error.BindingTimerFailed,
        host_inputs.handleBindingTimeout(harness.client, error.BindingTimerFailed),
    );
    try std.testing.expect(!harness.client.host_input.binding_timeout.pending);
}

test "a Kitty capability response commits before fallback projection and presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    var payload: [256]u8 = undefined;
    const encoded = try schema.encodeGraphicsImage(&payload, .{
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
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(encoded));
    try std.testing.expect(client.model.workspace.findPane(TestHarness.bootstrap_pane).?.graphics_placeholder);
    const version = client.model.version();
    const pending_updates = client.presenter.pending_updates;
    var handler: InputHandler = .{ .client = client };

    try handler.terminalResponse(.{ .kitty_graphics = .{
        .image_id = kitty.query_image_id,
        .supported = true,
    } });

    try std.testing.expect(!handler.redraw);
    try std.testing.expectEqual(kitty.Support.supported, client.model.hostCapabilities().kitty_graphics);
    try std.testing.expect(!client.model.workspace.findPane(TestHarness.bootstrap_pane).?.graphics_placeholder);
    try std.testing.expectEqual(version.host_capabilities + 1, client.model.version().host_capabilities);
    try std.testing.expectEqual(version.pane_graphics + 1, client.model.version().pane_graphics);
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates + 1, client.presenter.pending_updates);
}

test "capability expiry commits fallback state and presents only by model version" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    const pending_updates = client.presenter.pending_updates;

    try client.handleCapabilityTimeoutEvent({});

    const capabilities = client.model.hostCapabilities();
    try std.testing.expectEqual(kitty.Support.unsupported, capabilities.kitty_graphics);
    try std.testing.expectEqual(kitty.Support.unsupported, capabilities.kitty_zlib);
    try std.testing.expectEqual(kitty.Support.unsupported, capabilities.mouse_pixels);
    try std.testing.expectEqual(client_model.Version{
        .host_capabilities = 1,
    }, client.model.version());
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();

    const version = client.model.version();
    const pending_after = client.presenter.pending_updates;
    try client.handleCapabilityTimeoutEvent({});
    try presentation_lifecycle.observe(client);
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(pending_after, client.presenter.pending_updates);
}

test "capability effect failure retains the committed fallback" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;
    client.sidebar_rendering = .kitty_hybrid;
    const pending_updates = client.presenter.pending_updates;

    try std.testing.expectError(
        error.KittyGraphicsUnsupported,
        client.handleCapabilityTimeoutEvent({}),
    );

    try std.testing.expectEqual(kitty.Support.unsupported, client.model.hostCapabilities().kitty_graphics);
    try std.testing.expectEqual(client_model.Version{
        .host_capabilities = 1,
    }, client.model.version());
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);
}

test "pane viewport intent commits before IPC and presenter-owned recomposition" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const pane = client.model.workspace.findPane(TestHarness.bootstrap_pane).?;
    const inactive_location = try harness.addInactiveTab(@enumFromInt(2), @enumFromInt(20));
    const inactive = client.model.workspace.find(inactive_location.tab_id).?;
    const active = client.model.workspace.active().?;
    pane.scroll = .{
        .total_rows = @as(u32, pane.buffer.h) + 10,
        .offset = 10,
    };
    active.model.composition_invalidated = false;
    inactive.model.composition_invalidated = false;
    const version = client.model.version();
    const pending_updates = client.presenter.pending_updates;
    const pane_view = active.model.viewForPane(pane.id, client.view.workbench()).?;
    var handler: InputHandler = .{ .client = client };
    try handler.mouse(.{
        .x = pane_view.content.x,
        .y = pane_view.content.y,
        .kind = .move,
    });
    handler.redraw = false;

    try handler.mouse(.{
        .x = pane_view.content.x,
        .y = pane_view.content.y,
        .kind = .scroll_up,
    });

    try std.testing.expectEqual(@as(u32, 7), pane.scroll.offset);
    try std.testing.expect(!client.graphics_store.paneVisible(pane.id));
    try std.testing.expect(!handler.redraw);
    try std.testing.expect(!active.model.composition_invalidated);
    try std.testing.expect(!inactive.model.composition_invalidated);
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);

    try handler.key(try keybind.parseKey("x"));

    try std.testing.expectEqual(@as(u32, 10), pane.scroll.offset);
    try std.testing.expect(client.graphics_store.paneVisible(pane.id));
    try std.testing.expectEqual(version.viewport + 2, client.model.version().viewport);
    try expectNonViewportVersionEqual(version, client.model.version());
    try std.testing.expect(!handler.redraw);
    try std.testing.expect(!active.model.composition_invalidated);
    try std.testing.expect(!inactive.model.composition_invalidated);
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);

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
    try std.testing.expectEqual(pending_updates + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expect(inactive.model.composition_invalidated);
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
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
    try client.graphics_store.setPaneVisible(pane.id, false);
    while (client.runtime_transport.outbox.hasCapacity()) {
        try client.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = pane.id } });
    }
    const version = client.model.version();
    const pending_updates = client.presenter.pending_updates;
    var handler: InputHandler = .{ .client = client };

    try std.testing.expectError(
        error.ClientOutboxFull,
        handler.key(try keybind.parseKey("x")),
    );

    try std.testing.expectEqual(@as(u32, 10), pane.scroll.offset);
    try std.testing.expect(client.graphics_store.paneVisible(pane.id));
    try std.testing.expectEqual(version.viewport + 1, client.model.version().viewport);
    try expectNonViewportVersionEqual(version, client.model.version());
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);
    try std.testing.expect(!handler.redraw);
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
    const pending_updates_before = client.presenter.pending_updates;

    var handler: InputHandler = .{ .client = client };
    try std.testing.expectEqual(
        keybind.Control.continue_routing,
        try client_actions.apply(handler.client, .enter_copy_mode),
    );
    try std.testing.expect(client.model.copyModeActive());
    try std.testing.expect(!handler.capturesKeys());
    try std.testing.expect(!name_prompts.beginActiveTabRename(client));
    try std.testing.expect(!client.model.name_prompt.active());
    try expectNonCopyVersionEqual(version_before, client.model.version());
    try std.testing.expectEqual(version_before.copy + 1, client.model.version().copy);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    try std.testing.expect(pane.copy_view == null);
    try std.testing.expect(!handler.redraw);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates_before + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expect(pane.copy_view != null);
    try std.testing.expectEqualDeep(client.model.copyModeProjection(), client.presenter.presented_copy_mode);
    const painted_cursor_y = pane.copy_view.?.cursor.y;

    const pane_view = client.model.workspace.active().?.model.viewForPane(
        pane.id,
        client.view.workbench(),
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
    try expectNonCopyOrViewportVersionEqual(mouse_version, client.model.version());
    try std.testing.expectEqual(painted_cursor_y - 3, client.model.copyModeProjection().?.view.cursor.y);
    try std.testing.expectEqual(painted_cursor_y, pane.copy_view.?.cursor.y);
    try std.testing.expect(!handler.redraw);

    // While in copy mode, keys route to the selection, not the pane.
    try handler.key(try keybind.parseKey("v"));
    try handler.key(try keybind.parseKey("l"));
    try std.testing.expectEqual(@as(u16, 0), pane.copy_view.?.cursor.x);
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    try std.testing.expectEqual(@as(u16, 1), pane.copy_view.?.cursor.x);
    try std.testing.expect(pane.copy_view.?.anchor != null);

    const version_before_copy = client.model.version();
    try handler.key(try keybind.parseKey("enter"));
    try std.testing.expect(!client.model.copyModeActive());
    try expectNonCopyOrViewportVersionEqual(version_before_copy, client.model.version());
    try std.testing.expectEqual(version_before_copy.copy + 1, client.model.version().copy);
    try std.testing.expectEqual(version_before_copy.viewport + 1, client.model.version().viewport);
    try std.testing.expect(pane.copy_view != null);
    try presentation_lifecycle.observe(client);
    try harness.settleModelPresentation();
    try std.testing.expect(pane.copy_view == null);
    try std.testing.expect(client.presenter.presented_copy_mode == null);
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);
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
    try handler.key(try keybind.parseKey("v"));
    const version = client.model.version();

    try std.testing.expectError(
        error.ClientOutboxFull,
        handler.key(try keybind.parseKey("enter")),
    );

    try std.testing.expect(client.model.copyModeActive());
    try std.testing.expect(client.model.copyModeProjection().?.view.anchor != null);
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(client_outbox.capacity, @as(usize, client.runtime_transport.outbox.len));
    try std.testing.expect(!handler.redraw);
}

test "workspace rename separates prompt submission canonical commit and presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version_before_prompt = client.model.version();
    const pending_updates_before_prompt = client.presenter.pending_updates;

    try std.testing.expect(name_prompts.beginWorkspaceRename(client));
    try std.testing.expect(client.model.name_prompt.active());
    try std.testing.expectEqualStrings("", client.model.name_prompt.currentConst().?.field.text());
    try expectNonPromptVersionEqual(version_before_prompt, client.model.version());
    try std.testing.expect(client.model.version().prompt > version_before_prompt.prompt);
    try std.testing.expectEqual(pending_updates_before_prompt, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);
    try std.testing.expectEqual(pending_updates_before_prompt + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);

    const version_before_request = client.model.version();
    const pending_updates_before_request = client.presenter.pending_updates;
    var handler: InputHandler = .{ .client = client };
    try handler.forward("mainx\r");

    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expect(!client.model.name_prompt.active());
    try std.testing.expectEqualStrings("", client.model.workspace.workspaceName());
    try expectNonPromptVersionEqual(version_before_request, client.model.version());
    try std.testing.expect(client.model.version().prompt > version_before_request.prompt);
    try std.testing.expectEqual(pending_updates_before_request, client.presenter.pending_updates);
    const version_after_request = client.model.version();
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .rename_workspace);
    try std.testing.expectEqualStrings("mainx", message.rename_workspace.name);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location.workspace, message.rename_workspace.workspace);

    var payload: [512]u8 = undefined;
    const renamed = try schema.encodeWorkspaceSnapshot(&payload, .{
        .request_id = message.rename_workspace.request_id,
        .workspace = message.rename_workspace.workspace,
        .name = message.rename_workspace.name,
        .tabs = &.{
            .{ .tab_id = TestHarness.bootstrap_location.tab_id, .position = 0, .pane_count = 1, .label = "main" },
        },
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(renamed));

    try std.testing.expectEqualStrings("mainx", client.model.workspace.workspaceName());
    try std.testing.expectEqual(version_before_request.workspace + 1, client.model.version().workspace);
    try std.testing.expectEqual(version_before_request.tabs, client.model.version().tabs);
    try std.testing.expectEqual(version_before_request.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(version_after_request.prompt, client.model.version().prompt);
    try std.testing.expectEqual(pending_updates_before_request, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_request + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);

    const version_before_noop = client.model.version();
    const pending_updates_before_noop = client.presenter.pending_updates;
    try client.request_lifecycle.tracker.add(@enumFromInt(90), .{
        .rename_workspace = TestHarness.bootstrap_location.workspace,
    });
    const unchanged = try schema.encodeWorkspaceSnapshot(&payload, .{
        .request_id = @enumFromInt(90),
        .workspace = TestHarness.bootstrap_location.workspace,
        .name = "mainx",
        .tabs = &.{
            .{ .tab_id = TestHarness.bootstrap_location.tab_id, .position = 0, .pane_count = 1, .label = "main" },
        },
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(unchanged));
    try presentation_lifecycle.observe(client);

    try std.testing.expectEqualDeep(version_before_noop, client.model.version());
    try std.testing.expectEqual(pending_updates_before_noop, client.presenter.pending_updates);
}

test "pending workspace operation keeps the rename prompt without sending" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    try client.request_lifecycle.tracker.add(@enumFromInt(90), .{
        .rename_workspace = TestHarness.bootstrap_location.workspace,
    });
    const next_request_id = client.request_lifecycle.next_request_id;
    const version_before_request = client.model.version();

    try std.testing.expect(name_prompts.beginWorkspaceRename(client));
    var handler: InputHandler = .{ .client = client };
    try handler.forward("x\r");

    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expect(client.model.name_prompt.active());
    try std.testing.expectEqual(next_request_id, client.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try expectNonPromptVersionEqual(version_before_request, client.model.version());
    try std.testing.expect(client.model.version().prompt > version_before_request.prompt);

    try handler.forward("\x1b");
    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expect(!client.model.name_prompt.active());
}

test "an unexpected tab rename is rejected without effects" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const version_before = client.model.version();
    const pending_updates_before = client.presenter.pending_updates;
    const renamed: schema.TabRenamed = .{
        .request_id = @enumFromInt(99),
        .location = TestHarness.bootstrap_location,
        .label = "canonical",
    };

    try std.testing.expectError(error.UnexpectedTabRenamed, tab_renames.apply(client, renamed));

    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqual(pending_updates_before, client.presenter.pending_updates);
    try std.testing.expectEqualStrings("main", client.model.workspace.activeConst().?.labelSlice());
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "tab rename consumes an incompatible continuation before rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const request_id: schema.RequestId = @enumFromInt(90);
    const version_before = client.model.version();
    try client.request_lifecycle.tracker.add(request_id, .notification);
    const renamed: schema.TabRenamed = .{
        .request_id = request_id,
        .location = TestHarness.bootstrap_location,
        .label = "canonical",
    };

    try std.testing.expectError(error.UnexpectedTabRenamed, tab_renames.apply(client, renamed));
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedTabRenamed, tab_renames.apply(client, renamed));
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqualStrings("main", client.model.workspace.activeConst().?.labelSlice());
}

test "tab rename consumes a mismatched location before rejection" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const request_id: schema.RequestId = @enumFromInt(90);
    const version_before = client.model.version();
    try client.request_lifecycle.tracker.add(request_id, .{ .rename_tab = TestHarness.bootstrap_location });
    const renamed: schema.TabRenamed = .{
        .request_id = request_id,
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(9) },
            .tab_id = TestHarness.bootstrap_location.tab_id,
        },
        .label = "canonical",
    };

    try std.testing.expectError(error.UnexpectedTabRenamed, tab_renames.apply(client, renamed));
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqualStrings("main", client.model.workspace.activeConst().?.labelSlice());
}

test "tab rename consumes a canonical response rejected by the model" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const request_id: schema.RequestId = @enumFromInt(90);
    const missing: schema.TabLocation = .{
        .workspace = TestHarness.bootstrap_location.workspace,
        .tab_id = @enumFromInt(9),
    };
    const version_before = client.model.version();
    try client.request_lifecycle.tracker.add(request_id, .{ .rename_tab = missing });
    const renamed: schema.TabRenamed = .{
        .request_id = request_id,
        .location = missing,
        .label = "canonical",
    };

    try std.testing.expectError(error.UnexpectedTabRenamed, tab_renames.apply(client, renamed));
    try std.testing.expectEqual(@as(usize, 0), client.request_lifecycle.tracker.count);
    try std.testing.expectError(error.UnexpectedTabRenamed, tab_renames.apply(client, renamed));
    try std.testing.expectEqualDeep(version_before, client.model.version());
    try std.testing.expectEqualStrings("main", client.model.workspace.activeConst().?.labelSlice());
}

test "tab rename separates prompt submission canonical commit and presentation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const version_before_request = client.model.version();
    const pending_updates_before_request = client.presenter.pending_updates;

    try std.testing.expect(name_prompts.beginTabRename(client, TestHarness.bootstrap_location.tab_id));
    var handler: InputHandler = .{ .client = client };
    try std.testing.expect(handler.capturesKeys());

    try handler.forward("x");
    try handler.forward("\r");
    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expect(!client.model.name_prompt.active());
    try std.testing.expectEqualStrings("main", client.model.workspace.activeConst().?.labelSlice());
    try expectNonPromptVersionEqual(version_before_request, client.model.version());
    try std.testing.expect(client.model.version().prompt > version_before_request.prompt);
    try std.testing.expectEqual(pending_updates_before_request, client.presenter.pending_updates);
    const version_after_request = client.model.version();
    try harness.settle();

    var buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&buffer);
    try std.testing.expect(message == .rename_tab);
    try std.testing.expectEqualStrings("mainx", message.rename_tab.label);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, message.rename_tab.location);
    const continuation = client.request_lifecycle.tracker.take(message.rename_tab.request_id).?;
    try std.testing.expect(continuation == .rename_tab);
    try std.testing.expectEqualDeep(TestHarness.bootstrap_location, continuation.rename_tab);
    try client.request_lifecycle.tracker.add(message.rename_tab.request_id, continuation);

    var payload: [256]u8 = undefined;
    const renamed = try schema.encodeTabRenamed(&payload, .{
        .request_id = message.rename_tab.request_id,
        .location = message.rename_tab.location,
        .label = "canonical",
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(renamed));
    @memset(&payload, 'x');

    try std.testing.expectEqualStrings("canonical", client.model.workspace.activeConst().?.labelSlice());
    try std.testing.expectEqual(version_before_request.tabs + 1, client.model.version().tabs);
    try std.testing.expectEqual(version_before_request.active_tab, client.model.version().active_tab);
    try std.testing.expectEqual(version_after_request.prompt, client.model.version().prompt);
    try std.testing.expectEqual(pending_updates_before_request, client.presenter.pending_updates);

    try presentation_lifecycle.observe(client);

    try std.testing.expectEqual(pending_updates_before_request + 1, client.presenter.pending_updates);
    try harness.settleModelPresentation();
    try std.testing.expectEqualDeep(client.model.version(), client.presenter.presented_model_version);

    const version_before_noop = client.model.version();
    const pending_updates_before_noop = client.presenter.pending_updates;
    try client.request_lifecycle.tracker.add(@enumFromInt(90), .{ .rename_tab = TestHarness.bootstrap_location });
    const unchanged = try schema.encodeTabRenamed(&payload, .{
        .request_id = @enumFromInt(90),
        .location = TestHarness.bootstrap_location,
        .label = "canonical",
    });
    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(unchanged));
    try presentation_lifecycle.observe(client);

    try std.testing.expectEqualDeep(version_before_noop, client.model.version());
    try std.testing.expectEqual(pending_updates_before_noop, client.presenter.pending_updates);
}

test "tab rename response must match the requested identity" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};

    try std.testing.expect(name_prompts.beginTabRename(client, TestHarness.bootstrap_location.tab_id));
    var handler: InputHandler = .{ .client = client };
    try handler.forward("x\r");
    const version_before_response = client.model.version();
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&message_buffer);
    var response_buffer: [256]u8 = undefined;
    const response = try schema.encodeTabRenamed(&response_buffer, .{
        .request_id = message.rename_tab.request_id,
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(9) },
            .tab_id = message.rename_tab.location.tab_id,
        },
        .label = "canonical",
    });

    try std.testing.expectError(
        error.UnexpectedTabRenamed,
        server_messages.handleServerMessage(client, try schema.decodeServer(response)),
    );

    try std.testing.expectEqualStrings("main", client.model.workspace.activeConst().?.labelSlice());
    try std.testing.expectEqualDeep(version_before_response, client.model.version());
    try std.testing.expect(!client.request_lifecycle.tracker.has(.tab_operation));
}

test "a failed tab rename preserves the label and notifies" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};

    try std.testing.expect(name_prompts.beginTabRename(client, TestHarness.bootstrap_location.tab_id));
    var handler: InputHandler = .{ .client = client };
    try handler.forward("x\r");
    const version_before_failure = client.model.version();
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const message = try harness.nextClientMessage(&message_buffer);
    var response_buffer: [256]u8 = undefined;
    const response = try schema.encodeRequestFailed(&response_buffer, .{
        .request_id = message.rename_tab.request_id,
        .code = .tab_not_found,
        .message = "tab not found",
    });

    _ = try server_messages.handleServerMessage(client, try schema.decodeServer(response));

    try std.testing.expectEqualStrings("main", client.model.workspace.activeConst().?.labelSlice());
    try expectOnlyNotificationVersionChanged(version_before_failure, client.model.version());
    try std.testing.expect(!client.request_lifecycle.tracker.has(.tab_operation));
    try std.testing.expect(client.notification_scheduler.pending);
}

test "pending tab operation keeps the rename prompt without sending" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    try client.request_lifecycle.tracker.add(@enumFromInt(90), .{ .move_tab = TestHarness.bootstrap_location });
    const next_request_id = client.request_lifecycle.next_request_id;
    const version_before_request = client.model.version();

    try std.testing.expect(name_prompts.beginTabRename(client, TestHarness.bootstrap_location.tab_id));
    var handler: InputHandler = .{ .client = client };
    try handler.forward("x\r");

    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expect(client.model.name_prompt.active());
    try std.testing.expectEqual(next_request_id, client.request_lifecycle.next_request_id);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
    try expectNonPromptVersionEqual(version_before_request, client.model.version());
    try std.testing.expect(client.model.version().prompt > version_before_request.prompt);

    try handler.forward("\x1b");
    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expect(!client.model.name_prompt.active());
}

test "a full outbox keeps the tab rename prompt and rolls back correlation" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};
    const version_before_request = client.model.version();
    while (client.runtime_transport.outbox.hasCapacity()) {
        try client.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = TestHarness.bootstrap_pane } });
    }

    try std.testing.expect(name_prompts.beginTabRename(client, TestHarness.bootstrap_location.tab_id));
    var handler: InputHandler = .{ .client = client };

    try std.testing.expectError(error.ClientOutboxFull, handler.forward("x\r"));

    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expect(client.model.name_prompt.active());
    try std.testing.expect(!client.request_lifecycle.tracker.has(.tab_operation));
    try std.testing.expectEqual(client_outbox.capacity, @as(usize, client.runtime_transport.outbox.len));
    try std.testing.expectEqualStrings("main", client.model.workspace.activeConst().?.labelSlice());
    try expectNonPromptVersionEqual(version_before_request, client.model.version());
    try std.testing.expect(client.model.version().prompt > version_before_request.prompt);
}

test "escaping the prompt editor closes model state without changing mode" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    client.request_lifecycle.tracker = .{};

    try std.testing.expect(name_prompts.beginWorkspaceCreate(client));
    try std.testing.expect(client.model.name_prompt.active());
    try std.testing.expect(!client.model.copyModeActive());
    var handler: InputHandler = .{ .client = client };
    try handler.forward("\x1b");
    try std.testing.expect(!client.model.copyModeActive());
    try std.testing.expect(!client.model.name_prompt.active());
}

test "client telemetry writes one snapshot without mutating semantic state" {
    if (!core.diagnostics.enabled) {
        return;
    }

    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const model_version = client.model.version();
    const presented_version = client.presenter.presented_model_version;
    const file = try temp.dir.createFile(io, "client.log", .{});
    client.telemetry.sink.deinit(io);
    client.telemetry.sink = .{ .file = file };
    client.telemetry.enabled = true;

    client_telemetry.handleTick(client, {}, .{ .observation_allocs = 7 });

    try std.testing.expect(client.telemetry.write_pending);
    const line_end = (std.mem.indexOfScalar(u8, &client.telemetry.buffer, '\n') orelse
        return error.TelemetryLineMissing) + 1;
    const line = client.telemetry.buffer[0..line_end];
    try std.testing.expect(std.mem.indexOf(u8, line, "\"role\":\"client\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"active_tab\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"observation_allocs\":7") != null);

    switch (try client.select.await()) {
        .telemetry_written => |result| client_telemetry.handleWritten(client, result),
        else => return error.UnexpectedEvent,
    }
    try std.testing.expect(!client.telemetry.write_pending);
    try std.testing.expect(client.telemetry.enabled);
    try std.testing.expect(client.telemetry.sink.available());
    try std.testing.expectEqualDeep(model_version, client.model.version());
    try std.testing.expectEqualDeep(presented_version, client.presenter.presented_model_version);

    client_telemetry.handleTick(client, error.TickFailed, .{});
    try std.testing.expect(!client.telemetry.enabled);
    try std.testing.expect(!client.telemetry.sink.available());
}
