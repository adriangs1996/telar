//! Substituted platform resources shared by client integration tests.

const view_chrome = @import("../presentation/view_chrome.zig");
const host_effects = @import("../resources/host_effects.zig");
const core = @import("telar-core");
const client_module = @import("telar-client");
const data = @import("model");
const ResourcesType = @import("../entrypoints/Resources.zig");
const std = @import("std");
const TestHarness = @import("TestHarness.zig");
const TerminalClient = @import("../TerminalClient.zig");
const TestingPlugin = @import("TestingPlugin.zig");

pub fn clientEventResourcesForTest(heap: *const core.Heap) ResourcesType {
    return .{
        .tty = undefined,
        .resize_watcher = undefined,
        .heap = heap,
    };
}

pub fn reportedPaneId(client: *const client_module.AttachedClient) ?core.PaneId {
    const reported = client.model.reported_pane_focus orelse return null;

    return reported.pane_id;
}

pub fn expectNonPromptVersionEqual(expected: data.Version, actual: data.Version) !void {
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

pub fn expectNonCopyVersionEqual(expected: data.Version, actual: data.Version) !void {
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

pub fn expectNonCopyOrViewportVersionEqual(expected: data.Version, actual: data.Version) !void {
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

pub fn expectNonViewportVersionEqual(expected: data.Version, actual: data.Version) !void {
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

pub fn expectOnlyNotificationVersionChanged(expected: data.Version, actual: data.Version) !void {
    try std.testing.expect(actual.notifications > expected.notifications);

    var normalized = actual;
    normalized.notifications = expected.notifications;
    try std.testing.expectEqualDeep(expected, normalized);
}

// ---------------------------------------------------------------------------
// Test harness: a real Client over substituted platform dependencies — a
// socketpair instead of the runtime socket, a pipe instead of the tty's read
// handle, and a discarding writer instead of the host terminal.

pub fn encodeTestingAgentSnapshot(buffer: []u8, revision: u64, status: core.AgentStatus) ![]const u8 {
    return core.encodeAgentSnapshot(buffer, .{
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

pub fn testingConfigAdoption(number: u64, changed: bool) !client_module.ConfigAdoption {
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

pub fn testingConfigAdoptionSource(number: u64, source: []const u8) !client_module.ConfigAdoption {
    var diagnostic: data.Diagnostic = .{};
    const generation = try client_module.Generation.loadSource(.{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .diagnostic = &diagnostic,
    }, .{
        .source = source,
        .source_name = "@client-reload-test",
        .number = number,
    });
    errdefer generation.deinit();
    const registry = try std.testing.allocator.create(client_module.Registry);
    errdefer std.testing.allocator.destroy(registry);
    registry.* = .{};
    const trust_store = try std.testing.allocator.create(core.TrustStore);
    errdefer std.testing.allocator.destroy(trust_store);
    trust_store.* = .{};
    return .{
        .generation = generation,
        .registry = registry,
        .trust_store = trust_store,
        .input = .{
            .prefix = generation.snapshot.prefix,
            .bindings = generation.snapshot.bindingSlice(),
            .escape_timeout_ns = generation.snapshot.input_escape_timeout_ns,
            .sequence_timeout_ns = generation.snapshot.input_sequence_timeout_ns,
        },
        .sidebar_rendering = generation.snapshot.sidebar_rendering,
    };
}

pub fn installTestingLuaBinding(client: *client_module.AttachedClient, source: []const u8) !data.Action {
    const adoption = try testingConfigAdoptionSource(1, source);
    std.debug.assert(adoption.generation.snapshot.binding_count == 1);
    const configured = adoption.generation.snapshot.bindings[0].action;
    _ = try reloadConfiguration(client, adoption);

    return configured;
}

pub const testing_plugin_context: data.CallbackContext = .{
    .sidebar_visible = true,
    .tab_count = 1,
    .active_tab_index = 0,
    .pane_count = 1,
    .focused_pane_id = @intFromEnum(TestHarness.bootstrap_pane),
};

pub fn installTestingPlugin(client: *client_module.AttachedClient) !TestingPlugin {
    std.debug.assert(client.plugin_registry == null);
    const manifest = try core.parseManifest(
        client.gpa,
        "{\"api_version\":1,\"id\":\"dev.telar.client-test\",\"version\":\"1\",\"entry\":\"plugin.lua\",\"source\":{\"url\":\"local:test\",\"revision\":\"one\"},\"actions\":[\"run\"],\"capabilities\":[\"runtime.control\"]}",
    );
    const digest: core.Digest = @splat(7);
    const registry = try client.gpa.create(client_module.Registry);
    registry.* = .{};
    registry.packages[0] = .{
        .manifest = manifest,
        .digest = digest,
        .root_len = 0,
    };
    registry.count = 1;
    client.plugin_registry = registry;

    return .{
        .action = .{
            .plugin = core.stableId(manifest.id()),
            .action = core.stableId("run"),
        },
        .digest = digest,
    };
}

pub fn installTestingAttachmentTarget(client: *client_module.AttachedClient, generation: u64) !data.AttachmentTarget {
    return installTestingAttachmentProvider(client, generation, .codex);
}

pub fn installTestingAttachmentProvider(client: *client_module.AttachedClient, generation: u64, provider: core.AgentProvider) !data.AttachmentTarget {
    const target: data.AttachmentTarget = .{
        .pane_id = TestHarness.bootstrap_pane,
        .pane_generation = generation,
    };
    _ = try client.model.reconcileAgentSnapshot(.{
        .revision = generation,
        .agents = &.{data.AgentInput{
            .key = .{
                .pane_id = target.pane_id,
                .pane_generation = target.pane_generation,
            },
            .location = TestHarness.bootstrap_location,
            .pane_index = 1,
            .provider = provider,
            .attachments = core.builtin_table.attachments(provider),
            .status = .working,
        }},
    });
    _ = try client.synchronizePaneAttachments();

    return target;
}

pub fn testingClipboardCapture(client: *client_module.AttachedClient, execution: data.ClipboardCapture, bytes: []const u8) !*data.Capture {
    const capture = try client.gpa.create(data.Capture);
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
    client.model.clipboard.orphan = capture;

    return capture;
}

pub fn reloadConfiguration(client: *client_module.AttachedClient, adoption: client_module.ConfigAdoption) !data.ConfigurationCommit {
    const outcome = try client.completeConfigReload(
        .{
            .loaded = .{
                .generation = adoption.generation,
                .registry = adoption.registry,
                .trust_store = adoption.trust_store,
                .mtime_ns = client.reload.mtime_ns,
            },
        },
    );
    try view_chrome.refreshClient(client);
    try host_effects.deliver(client);

    return outcome.adopted;
}

/// Receives the next inbox event and returns it when it belongs to the
/// shared client.
/// Example: `switch (try support.receiveClient(client)) { .sent => |result| try client.completeRuntimeSend(result), else => return error.UnexpectedEvent }`
pub fn receiveClient(client: *client_module.AttachedClient) !client_module.Message {
    return switch (try TerminalClient.of(client).inbox.receive()) {
        .client => |message| message,
        else => error.UnexpectedEvent,
    };
}
