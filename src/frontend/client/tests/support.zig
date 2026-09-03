//! Substituted platform resources shared by client integration tests.

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
const bar_updates = @import("../controllers/configuration/bar_updates.zig");
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

pub fn clientEventResourcesForTest(heap: *const core.diagnostics.Heap) client_events.Resources {
    return .{
        .tty = undefined,
        .resize_watcher = undefined,
        .heap = heap,
    };
}

pub fn reportedPaneId(client: *const Client) ?schema.PaneId {
    const reported = client.model.reportedPaneFocus() orelse return null;

    return reported.pane_id;
}

pub fn expectNonPromptVersionEqual(expected: client_model.Version, actual: client_model.Version) !void {
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
    try std.testing.expectEqual(expected.bars, actual.bars);
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

pub fn expectNonCopyVersionEqual(expected: client_model.Version, actual: client_model.Version) !void {
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
    try std.testing.expectEqual(expected.bars, actual.bars);
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

pub fn expectNonCopyOrViewportVersionEqual(expected: client_model.Version, actual: client_model.Version) !void {
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
    try std.testing.expectEqual(expected.bars, actual.bars);
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

pub fn expectNonViewportVersionEqual(expected: client_model.Version, actual: client_model.Version) !void {
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
    try std.testing.expectEqual(expected.bars, actual.bars);
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

pub fn expectOnlyNotificationVersionChanged(expected: client_model.Version, actual: client_model.Version) !void {
    try std.testing.expect(actual.notifications > expected.notifications);

    var normalized = actual;
    normalized.notifications = expected.notifications;
    try std.testing.expectEqualDeep(expected, normalized);
}

// ---------------------------------------------------------------------------
// Test harness: a real Client over substituted platform dependencies — a
// socketpair instead of the runtime socket, a pipe instead of the tty's read
// handle, and a discarding writer instead of the host terminal.

pub const TestHarness = struct {
    connection: core.transport.SocketChannel,
    peer: core.transport.SocketChannel,
    input_read: File,
    input_write: File,
    sink: Io.Writer.Discarding,
    client: *Client,

    pub fn init(harness: *TestHarness) !void {
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

    pub fn deinit(harness: *TestHarness) void {
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
    pub fn settle(harness: *TestHarness) !void {
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
                .bar_tick => |result| {
                    try bar_updates.handleTick(harness.client, result);
                    try presentation_lifecycle.observe(harness.client);
                },
                .bar_command => |completion| {
                    try bar_updates.completeCommand(harness.client, completion);
                    try presentation_lifecycle.observe(harness.client);
                },
                else => return error.UnexpectedEvent,
            }
        }
    }

    pub fn settleModelPresentation(harness: *TestHarness) !void {
        var target = harness.client.model.version();
        const graphics_target = harness.client.graphics_store.ingressVersion();
        const attachment_target = harness.client.view.kittyAttachments().ingressVersion();
        const view_interaction_target = harness.client.view.interactionVersion();
        const input_routing_target = harness.client.host_input.presentationVersion();
        while (!std.meta.eql(harness.client.presenter.presented_model_version, target) or
            harness.client.presenter.presented_graphics_ingress != graphics_target or
            harness.client.presenter.presented_attachment_ingress != attachment_target or
            harness.client.presenter.presented_presentation_ingress.view_interaction !=
                view_interaction_target or
            harness.client.presenter.presented_presentation_ingress.input_routing !=
                input_routing_target)
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
                .bar_tick => |result| {
                    try bar_updates.handleTick(harness.client, result);
                    try presentation_lifecycle.observe(harness.client);
                    target = harness.client.model.version();
                },
                .bar_command => |completion| {
                    try bar_updates.completeCommand(harness.client, completion);
                    try presentation_lifecycle.observe(harness.client);
                    target = harness.client.model.version();
                },
                else => return error.UnexpectedEvent,
            }
        }
    }

    /// Receives the next message the client sent to the runtime.
    pub fn nextClientMessage(harness: *TestHarness, buffer: []u8) !schema.ClientMessage {
        const payload = try harness.peer.receive(std.testing.io, buffer);
        return schema.decodeClient(payload);
    }

    pub fn nextAttachmentRequest(harness: *TestHarness, pane_id: schema.PaneId, buffer: []u8) !schema.RequestId {
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

    pub fn discoverAndRequestAttachment(harness: *TestHarness, pane_id: schema.PaneId, buffer: []u8) !schema.RequestId {
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

    pub const bootstrap_location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    pub const bootstrap_pane: schema.PaneId = @enumFromInt(10);

    /// Answers the initial open request through the real entrypoint, leaving
    /// the client with one attached pane and its two snapshot requests (ids
    /// 2 and 3) delivered to the peer.
    pub fn bootstrap(harness: *TestHarness) !void {
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

    pub fn addTab(harness: *TestHarness, tab_id: schema.TabId, pane_id: schema.PaneId) !schema.TabLocation {
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

    pub fn addInactiveTab(harness: *TestHarness, tab_id: schema.TabId, pane_id: schema.PaneId) !schema.TabLocation {
        const location = try harness.addTab(tab_id, pane_id);
        const tab = harness.client.model.workspace.find(tab_id).?;
        workspace_capability.tabs.Model.detachAll(tab);
        try harness.client.graphics_store.setPaneVisible(pane_id, false);
        try std.testing.expect(harness.client.model.workspace.select(bootstrap_location.tab_id));

        return location;
    }

    pub fn allowTabSelection(harness: *TestHarness) !void {
        const continuation = request_lifecycle.consume(harness.client, @enumFromInt(3)) orelse
            return error.MissingBootstrapTabSnapshot;
        try std.testing.expect(continuation == .tab_snapshot);
    }
};

pub fn encodeTestingAgentSnapshot(buffer: []u8, revision: u64, status: schema.AgentStatus) ![]const u8 {
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
            .display_name = "Claude",
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

pub fn testingConfigAdoption(number: u64, changed: bool) !config_reloads.Adoption {
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

pub fn testingConfigAdoptionSource(number: u64, source: []const u8) !config_reloads.Adoption {
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

pub fn installTestingLuaBinding(client: *Client, source: []const u8) !input_capability.action.Action {
    const adoption = try testingConfigAdoptionSource(1, source);
    std.debug.assert(adoption.generation.snapshot.binding_count == 1);
    const configured = adoption.generation.snapshot.bindings[0].action;
    _ = try config_reloads.apply(client, adoption);

    return configured;
}

pub const TestingPlugin = struct {
    action: input_capability.action.PluginAction,
    digest: core.plugin.Digest,
};

pub const testing_plugin_context: lua_config.CallbackContext = .{
    .sidebar_visible = true,
    .tab_count = 1,
    .active_tab_index = 0,
    .pane_count = 1,
    .focused_pane_id = @intFromEnum(TestHarness.bootstrap_pane),
};

pub fn installTestingPlugin(client: *Client) !TestingPlugin {
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

pub fn installTestingAttachmentTarget(client: *Client, generation: u64) !attachments.Target {
    return installTestingAttachmentProvider(client, generation, .codex);
}

pub fn installTestingAttachmentProvider(client: *Client, generation: u64, provider: schema.AgentProvider) !attachments.Target {
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
            .provider = provider,
            .attachments = core.agent_manifest.builtin_table.attachments(provider),
            .status = .working,
        }},
    });
    _ = try active_pane_resources.synchronizeAttachments(client);

    return target;
}

pub fn testingClipboardCapture(client: *Client, execution: client_model.ClipboardCapture, bytes: []const u8) !*attachments.Capture {
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
