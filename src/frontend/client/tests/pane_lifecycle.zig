//! Client integration tests for pane lifecycle.

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
    const version_before = client.model.version();
    var press = point;
    press.kind = .press;

    try handler.mouse(press);

    try std.testing.expectEqual(first, model.layout.focused().?);
    try std.testing.expectEqual(version_before.panes + 1, client.model.version().panes);
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
    try std.testing.expect(!client.view.dirty);

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
}

test "pane fullscreen publishes visible geometry without direct presentation scheduling" {
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
    try std.testing.expect(!client.view.dirty);

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

test "sidebar resize keybinding commits width before pane geometry" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const version = client.model.version();

    _ = try client_actions.apply(client, .{ .resize_sidebar = .left });

    try std.testing.expectEqual(@as(u16, 58), client.model.sidebarWidth());
    try std.testing.expectEqual(@as(u16, 58), client.view.regions.sidebar.w);
    try std.testing.expectEqual(version.chrome + 1, client.model.version().chrome);
    try harness.settle();
    var buffer: [256]u8 = undefined;
    const resized = try harness.nextClientMessage(&buffer);
    try std.testing.expect(resized == .pane_resize);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, resized.pane_resize.pane_id);
    try std.testing.expectEqual(
        schema.TerminalSize{ .cols = 22, .rows = 22 },
        resized.pane_resize.size,
    );
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

    try std.testing.expectError(error.StaleSidebarLayout, sidebar_projection.apply(client, .{
        .visible = true,
        .chrome_revision = committed.chrome_revision - 1,
    }));
    try std.testing.expectError(error.StaleSidebarLayout, sidebar_projection.apply(client, .{
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
    try tab_attachments.detach(client, client.model.workspace.active().?.location);
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

    try tab_attachments.detach(client, client.model.workspace.active().?.location);

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

    try active_pane_resources.synchronize(client);
    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const focus_in = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(focus_in == .pane_input);
    try std.testing.expectEqualStrings("\x1b[I", focus_in.pane_input.bytes);

    try tab_attachments.detach(client, client.model.workspace.active().?.location);

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
    try active_pane_resources.synchronize(client);
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

    try tab_attachments.detach(client, tab.location);

    try std.testing.expectEqualDeep(reported, client.model.reportedPaneFocus().?);
    try harness.settle();
    const detached = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(inactive_pane, detached.detach_pane.pane_id);
    try std.testing.expectEqual(@as(usize, 0), client.runtime_transport.outbox.len);
}

test "detach action releases every tab before stopping the client" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const second_pane: schema.PaneId = @enumFromInt(20);
    _ = try harness.addTab(@enumFromInt(2), second_pane);
    const version = client.model.version();
    const pending_updates = client.presenter.pending_updates;

    try std.testing.expectEqual(
        keybind.Control.stop,
        try client_actions.apply(client, .detach),
    );

    try std.testing.expect(!client.model.workspace.findPane(TestHarness.bootstrap_pane).?.attached);
    try std.testing.expect(!client.model.workspace.findPane(second_pane).?.attached);
    try std.testing.expect(!client.graphics_store.paneVisible(TestHarness.bootstrap_pane));
    try std.testing.expect(!client.graphics_store.paneVisible(second_pane));
    try std.testing.expectEqualDeep(version, client.model.version());
    try std.testing.expectEqual(pending_updates, client.presenter.pending_updates);

    try harness.settle();
    var message_buffer: [256]u8 = undefined;
    const first = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(first == .detach_pane);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, first.detach_pane.pane_id);
    const second = try harness.nextClientMessage(&message_buffer);
    try std.testing.expect(second == .detach_pane);
    try std.testing.expectEqual(second_pane, second.detach_pane.pane_id);
}

test "detach action captures layout changes from the same input batch" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const active = client.model.workspace.active().?;
    active.snapshot_loaded = true;
    try client.client_layouts.markSnapshotReceived();

    _ = try client_actions.apply(client, .{ .resize_sidebar = .left });
    try std.testing.expectEqual(keybind.Control.stop, try client_actions.apply(client, .detach));
    try harness.settle();

    var buffer: [schema.max_client_layout_wire_bytes]u8 = undefined;
    const resized = try harness.nextClientMessage(&buffer);
    try std.testing.expect(resized == .pane_resize);
    const retained = try harness.nextClientMessage(&buffer);
    try std.testing.expect(retained == .update_client_layout);
    try std.testing.expectEqual(@as(u16, 58), retained.update_client_layout.sidebar_width);
    const detached = try harness.nextClientMessage(&buffer);
    try std.testing.expect(detached == .detach_pane);
    try std.testing.expectEqual(TestHarness.bootstrap_pane, detached.detach_pane.pane_id);
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
