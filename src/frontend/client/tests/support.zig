//! Substituted platform resources shared by client integration tests.

const HeapType = @import("telar-core").Heap;
const ResourcesType = @import("../entrypoints/Resources.zig");
const Client = @import("telar-client").AttachedClient;
const PaneIdType = @import("telar-core").PaneId;
const VersionType = @import("telar-client").Version;
const std = @import("std");
const AgentStatusType = @import("telar-core").AgentStatus;
const encodeAgentSnapshot_module = @import("telar-core").encodeAgentSnapshot;
const TestHarness = @import("TestHarness.zig");
const AdoptionType = @import("telar-client").ConfigAdoption;
const DiagnosticType = @import("telar-client").Diagnostic;
const GenerationType = @import("telar-client").Generation;
const RegistryType = @import("telar-client").Registry;
const TrustStoreType = @import("telar-core").TrustStore;
const host_inputs = @import("../controllers/input/host_inputs.zig");
const ActionType = @import("telar-client").Action;
const config_reloads = @import("telar-client").controllers.config_reloads;
const CallbackContextType = @import("telar-client").CallbackContext;
const TestingPlugin = @import("TestingPlugin.zig");
const parseManifest_module = @import("telar-core").parseManifest;
const DigestType = @import("telar-core").Digest;
const stableId_module = @import("telar-core").stableId;
const TargetType = @import("telar-client").AttachmentTarget;
const AgentProviderType = @import("telar-core").AgentProvider;
const AgentInputType = @import("telar-client").AgentInput;
const builtin_table_module = @import("telar-core").builtin_table;
const active_pane_resources = @import("telar-client").controllers.active_pane_resources;
const ClipboardCaptureType = @import("telar-client").ClipboardCapture;
const CaptureType = @import("telar-client").Capture;

pub fn clientEventResourcesForTest(heap: *const HeapType) ResourcesType {
    return .{
        .tty = undefined,
        .resize_watcher = undefined,
        .heap = heap,
    };
}

pub fn reportedPaneId(client: *const Client) ?PaneIdType {
    const reported = client.model.reportedPaneFocus() orelse return null;

    return reported.pane_id;
}

pub fn expectNonPromptVersionEqual(expected: VersionType, actual: VersionType) !void {
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

pub fn expectNonCopyVersionEqual(expected: VersionType, actual: VersionType) !void {
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

pub fn expectNonCopyOrViewportVersionEqual(expected: VersionType, actual: VersionType) !void {
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

pub fn expectNonViewportVersionEqual(expected: VersionType, actual: VersionType) !void {
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

pub fn expectOnlyNotificationVersionChanged(expected: VersionType, actual: VersionType) !void {
    try std.testing.expect(actual.notifications > expected.notifications);

    var normalized = actual;
    normalized.notifications = expected.notifications;
    try std.testing.expectEqualDeep(expected, normalized);
}

// ---------------------------------------------------------------------------
// Test harness: a real Client over substituted platform dependencies — a
// socketpair instead of the runtime socket, a pipe instead of the tty's read
// handle, and a discarding writer instead of the host terminal.

pub fn encodeTestingAgentSnapshot(buffer: []u8, revision: u64, status: AgentStatusType) ![]const u8 {
    return encodeAgentSnapshot_module(buffer, .{
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

pub fn testingConfigAdoption(number: u64, changed: bool) !AdoptionType {
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

pub fn testingConfigAdoptionSource(number: u64, source: []const u8) !AdoptionType {
    var diagnostic: DiagnosticType = .{};
    const generation = try GenerationType.loadSource(.{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .diagnostic = &diagnostic,
    }, .{
        .source = source,
        .source_name = "@client-reload-test",
        .number = number,
    });
    errdefer generation.deinit();
    const registry = try std.testing.allocator.create(RegistryType);
    errdefer std.testing.allocator.destroy(registry);
    registry.* = .{};
    const trust_store = try std.testing.allocator.create(TrustStoreType);
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

pub fn installTestingLuaBinding(client: *Client, source: []const u8) !ActionType {
    const adoption = try testingConfigAdoptionSource(1, source);
    std.debug.assert(adoption.generation.snapshot.binding_count == 1);
    const configured = adoption.generation.snapshot.bindings[0].action;
    _ = try config_reloads.apply(client, adoption);

    return configured;
}

pub const testing_plugin_context: CallbackContextType = .{
    .sidebar_visible = true,
    .tab_count = 1,
    .active_tab_index = 0,
    .pane_count = 1,
    .focused_pane_id = @intFromEnum(TestHarness.bootstrap_pane),
};

pub fn installTestingPlugin(client: *Client) !TestingPlugin {
    std.debug.assert(client.plugin_registry == null);
    const manifest = try parseManifest_module(
        client.gpa,
        "{\"api_version\":1,\"id\":\"dev.telar.client-test\",\"version\":\"1\",\"entry\":\"plugin.lua\",\"source\":{\"url\":\"local:test\",\"revision\":\"one\"},\"actions\":[\"run\"],\"capabilities\":[\"runtime.control\"]}",
    );
    const digest: DigestType = @splat(7);
    const registry = try client.gpa.create(RegistryType);
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
            .plugin = stableId_module(manifest.id()),
            .action = stableId_module("run"),
        },
        .digest = digest,
    };
}

pub fn installTestingAttachmentTarget(client: *Client, generation: u64) !TargetType {
    return installTestingAttachmentProvider(client, generation, .codex);
}

pub fn installTestingAttachmentProvider(client: *Client, generation: u64, provider: AgentProviderType) !TargetType {
    const target: TargetType = .{
        .pane_id = TestHarness.bootstrap_pane,
        .pane_generation = generation,
    };
    _ = try client.model.reconcileAgentSnapshot(.{
        .revision = generation,
        .agents = &.{AgentInputType{
            .key = .{
                .pane_id = target.pane_id,
                .pane_generation = target.pane_generation,
            },
            .location = TestHarness.bootstrap_location,
            .pane_index = 1,
            .provider = provider,
            .attachments = builtin_table_module.attachments(provider),
            .status = .working,
        }},
    });
    _ = try active_pane_resources.synchronizeAttachments(client);

    return target;
}

pub fn testingClipboardCapture(client: *Client, execution: ClipboardCaptureType, bytes: []const u8) !*CaptureType {
    const capture = try client.gpa.create(CaptureType);
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
