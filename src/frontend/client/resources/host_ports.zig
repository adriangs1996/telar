//! Terminal implementations of the client's host service ports. Each port
//! binds one heap-stable client so workers complete through its event loop.

const tab_drag = @import("../controllers/input/tab_drag.zig");
const client_module = @import("telar-client");
const data = @import("model");
const core = @import("telar-core");
const TerminalClient = @import("../TerminalClient.zig");
const platform = @import("../../platform/platform.zig");
const host_inputs = @import("../controllers/input/host_inputs.zig");
const history_inspection = @import("../presentation/history_inspection.zig");
const kitty_delivery = @import("../../graphics/kitty_delivery.zig");
const sound_worker = @import("../../sound/worker.zig");
const notification_host = @import("../../notifications/host.zig");
const PayloadType = @import("../../notifications/Payload.zig");
const link_host = @import("../../links/host.zig");
const capture_module = @import("../../attachments/capture.zig");
const term = @import("../../presentation/screen_support.zig");
const std = @import("std");

/// Example: `client.sound_port = host_ports.sound(client);`.
pub fn sound(client: *client_module.AttachedClient) client_module.SoundPort {
    return .{ .context = client, .play = playSound };
}

/// Example: `client.notifier = host_ports.notifier(client);`.
pub fn notifier(client: *client_module.AttachedClient) client_module.HostNotifier {
    return .{ .context = client, .deliver = deliverNotification };
}

/// Example: `client.link_opener = host_ports.links(client);`.
pub fn links(client: *client_module.AttachedClient) client_module.LinkOpener {
    return .{ .context = client, .open = openLink };
}

/// Example: `client.capture_port = host_ports.capture(client);`.
pub fn capture(client: *client_module.AttachedClient) client_module.CapturePort {
    return .{ .context = client, .supported = captureSupported, .start = startCapture };
}

/// Example: `client.host_clipboard = host_ports.clipboard(client);`.
pub fn clipboard(client: *client_module.AttachedClient) client_module.HostClipboard {
    return .{ .context = client, .set = setClipboard };
}

/// Example: `client.host_graphics = host_ports.graphics(client);`.
pub fn graphics(client: *client_module.AttachedClient) client_module.HostGraphics {
    return .{ .context = client, .invalidate_placements = invalidatePlacements };
}

/// Example: `client.graphics = host_ports.graphicsRetention(client);`.
pub fn graphicsRetention(client: *client_module.AttachedClient) client_module.GraphicsRetention {
    return .{
        .context = client,
        .apply_fn = applyGraphics,
        .clear_pane_fn = clearPaneGraphics,
        .set_pane_visible_fn = setPaneGraphicsVisible,
        .pane_visible_fn = paneGraphicsVisible,
        .has_pane_graphics_fn = hasPaneGraphics,
        .ingress_version_fn = graphicsIngressVersion,
        .peek_credit_fn = peekGraphicsCredit,
        .consume_credit_fn = consumeGraphicsCredit,
    };
}

fn applyGraphics(context: *anyopaque, command: data.PaneGraphicsCommand) !void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    return switch (command) {
        .snapshot => |message| TerminalClient.of(client).graphics_store.applySnapshot(message),
        .image => |message| TerminalClient.of(client).graphics_store.applyImage(message),
        .shared_image => |message| TerminalClient.of(client).graphics_store.applySharedImage(message),
        .image_chunk => |message| TerminalClient.of(client).graphics_store.applyChunk(message),
        .placement => |message| TerminalClient.of(client).graphics_store.applyPlacement(message),
        .delete_image => |message| TerminalClient.of(client).graphics_store.deleteImage(message),
        .delete_placement => |message| TerminalClient.of(client).graphics_store.deletePlacement(message),
    };
}

fn clearPaneGraphics(context: *anyopaque, pane_id: core.PaneId) void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    TerminalClient.of(client).graphics_store.clearPane(pane_id);
}

fn setPaneGraphicsVisible(context: *anyopaque, pane_id: core.PaneId, visible: bool) !void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    try TerminalClient.of(client).graphics_store.setPaneVisible(pane_id, visible);
}

fn paneGraphicsVisible(context: *anyopaque, pane_id: core.PaneId) bool {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    return TerminalClient.of(client).graphics_store.paneVisible(pane_id);
}

fn hasPaneGraphics(context: *anyopaque, pane_id: core.PaneId) bool {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    return TerminalClient.of(client).graphics_store.hasPaneGraphics(pane_id);
}

fn graphicsIngressVersion(context: *anyopaque) u64 {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    return TerminalClient.of(client).graphics_store.ingressVersion();
}

fn peekGraphicsCredit(context: *anyopaque) ?client_module.GraphicsCredit {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    return TerminalClient.of(client).graphics_store.peekCredit();
}

fn consumeGraphicsCredit(context: *anyopaque, credit: client_module.GraphicsCredit) void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    TerminalClient.of(client).graphics_store.consumeCredit(credit);
}

/// Queues deletes for every emitted Kitty placement and marks them dirty.
fn invalidatePlacements(context: *anyopaque) void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    kitty_delivery.invalidatePlacements(&TerminalClient.of(client).graphics_store);
}

fn playSound(context: *anyopaque, kind: core.AgentSound) !void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    try TerminalClient.of(client).inbox.start(.sound_played, .{ sound_worker.play, .{ client.io, kind } });
}

/// `terminal` adds OSC 9 for the outer terminal and `system` posts through
/// the operating system on a worker whose scheduling failure is not fatal.
fn deliverNotification(context: *anyopaque, channel: data.NotificationDelivery, input: data.NotificationInput) !void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    switch (channel) {
        .telar => {},
        .terminal => {
            const payload = PayloadType.init(input.title, input.message);
            try term.writeHostNotification(TerminalClient.of(client).writer, payload.titleSlice(), payload.messageSlice());
            try TerminalClient.of(client).writer.flush();
        },
        .system => {
            const payload = PayloadType.init(input.title, input.message);
            TerminalClient.of(client).inbox.start(.notified, .{ notification_host.notify, .{ client.io, payload } }) catch {};
        },
    }
}

fn openLink(context: *anyopaque, target: data.LinkTarget) !void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    try TerminalClient.of(client).inbox.start(.link_opened, .{ link_host.open, .{ client.io, target } });
}

fn captureSupported(_: *anyopaque) bool {
    return capture_module.platformSupported();
}

fn startCapture(context: *anyopaque, request: client_module.CaptureRequest) !void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    try TerminalClient.of(client).inbox.start(.clipboard_image, .{ executeCapture, .{
        client.gpa,
        request,
        &client.clipboard_capture_resources.orphan,
    } });
}

fn executeCapture(gpa: std.mem.Allocator, request: client_module.CaptureRequest, orphan: *?*client_module.Capture) client_module.operations.ClipboardImageCompletion {
    return .{
        .execution_id = @enumFromInt(request.sequence),
        .result = capture_module.captureClipboard(gpa, request, orphan),
    };
}

/// Writes one borrowed payload as OSC 52 and flushes it.
fn setClipboard(context: *anyopaque, bytes: []const u8) !void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    try term.writeClipboard(TerminalClient.of(client).writer, bytes);
    try TerminalClient.of(client).writer.flush();
}

/// Example: `client.chrome = host_ports.chrome(client);`.
pub fn chrome(client: *client_module.AttachedClient) client_module.HostChrome {
    return .{
        .context = client,
        .set_theme_fn = setTheme,
        .set_icon_theme_fn = setIconTheme,
        .configure_sidebar_fn = configureSidebar,
        .resize_fn = resizeView,
        .set_sidebar_layout_fn = setSidebarLayout,
        .set_workspace_list_collapsed_fn = setWorkspaceListCollapsed,
        .pointer_fn = pointer,
        .sidebar_renderer_fn = sidebarRenderer,
        .adopt_sidebar_renderer_fn = adoptSidebarRenderer,
        .region_fn = region,
        .inspection_scroll_limit_fn = inspectionScrollLimit,
    };
}

fn inspectionScrollLimit(context: *anyopaque) ?u32 {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    return history_inspection.scrollLimit(&client.model);
}

fn sidebarRenderer(context: *anyopaque) client_module.SidebarRendering {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    return TerminalClient.of(client).sidebar_rendering;
}

fn adoptSidebarRenderer(context: *anyopaque, value: client_module.SidebarRendering) void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    TerminalClient.of(client).sidebar_rendering = value;
}

fn region(context: *anyopaque) data.Region {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    return TerminalClient.of(client).view.geometry();
}

fn setTheme(context: *anyopaque, theme: client_module.ColorTheme) void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    TerminalClient.of(client).view.setTheme(theme);
}

fn setIconTheme(context: *anyopaque, theme: client_module.Theme) void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    TerminalClient.of(client).view.setIconTheme(theme);
}

/// The requested renderer is the adapter's own configuration.
fn configureSidebar(context: *anyopaque, input: client_module.SidebarRendererInput) !void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    try TerminalClient.of(client).view.configureSidebar(TerminalClient.of(client).sidebar_rendering, input);
}

fn resizeView(context: *anyopaque, cols: u16, rows: u16) !void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    try TerminalClient.of(client).view.resize(cols, rows);
}

fn setSidebarLayout(context: *anyopaque, visible: bool, width: u16) void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    TerminalClient.of(client).view.setSidebarLayout(visible, width);
}

fn setWorkspaceListCollapsed(context: *anyopaque, collapsed: bool) void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    TerminalClient.of(client).view.setWorkspaceListCollapsed(collapsed);
}

fn pointer(context: *anyopaque, event: data.Mouse) client_module.ViewInteractionCommand {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    if (tab_drag.press(client, event)) |interaction| {
        return interaction;
    }

    const interaction = TerminalClient.of(client).view.handleMouse(event);
    if (interaction.intent == .select_tab or interaction.intent == .rename_tab) {
        return .{ .consumed = true };
    }

    return interaction;
}

/// Example: `client.attachment_catalog = host_ports.attachmentCatalog(client);`.
pub fn attachmentCatalog(client: *client_module.AttachedClient) client_module.AttachmentCatalogPort {
    return .{
        .context = client,
        .visible_target_fn = visibleAttachmentTarget,
        .plan_marker_removal_fn = planMarkerRemoval,
        .id_at_marker_deletion_fn = idAtMarkerDeletion,
        .pending_marker_at_deletion_fn = pendingMarkerAtDeletion,
        .expect_marker_deletion_fn = expectMarkerDeletion,
    };
}

fn visibleAttachmentTarget(context: *anyopaque) ?data.AttachmentTarget {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    return TerminalClient.of(client).view.kittyAttachments().visibleTarget();
}

fn planMarkerRemoval(context: *anyopaque, id: data.AttachmentId, screen: client_module.MarkerScreen) ?data.MarkerRemoval {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    return TerminalClient.of(client).view.kittyAttachments().planMarkerRemoval(id, screen);
}

fn idAtMarkerDeletion(context: *anyopaque, screen: client_module.MarkerScreen, deletion: data.AttachmentMarkerDeletion) ?data.AttachmentId {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    return TerminalClient.of(client).view.kittyAttachments().idAtMarkerDeletion(screen, deletion);
}

fn pendingMarkerAtDeletion(context: *anyopaque, screen: client_module.MarkerScreen, probe: client_module.DeletionProbe) bool {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    return TerminalClient.of(client).view.kittyAttachments().pendingMarkerAtDeletion(screen, probe);
}

fn expectMarkerDeletion(context: *anyopaque, target: data.AttachmentTarget) void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    TerminalClient.of(client).view.kittyAttachments().expectMarkerDeletion(target);
}

/// Example: `client.attachment_shelf = host_ports.attachmentShelf(client);`.
pub fn attachmentShelf(client: *client_module.AttachedClient) client_module.AttachmentShelf {
    return .{
        .context = client,
        .adopt_fn = adoptAttachment,
        .reconcile_markers_fn = reconcileAttachmentMarkers,
        .sync_target_fn = syncAttachmentTarget,
        .remove_fn = removeAttachment,
        .remove_prompt_fn = removePromptAttachments,
        .modal_active_fn = attachmentModalActive,
        .close_modal_fn = closeAttachmentModal,
        .reservation_fn = attachmentReservation,
    };
}

fn adoptAttachment(context: *anyopaque, value: *client_module.Capture) !bool {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    return TerminalClient.of(client).view.adoptAttachment(value);
}

fn reconcileAttachmentMarkers(context: *anyopaque, target: data.AttachmentTarget, screen: client_module.MarkerScreen) ?bool {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    return TerminalClient.of(client).view.reconcileAttachmentMarkers(target, screen);
}

fn syncAttachmentTarget(context: *anyopaque, target: ?data.AttachmentTarget) bool {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    return TerminalClient.of(client).view.syncAttachmentTarget(target);
}

fn removeAttachment(context: *anyopaque, id: data.AttachmentId) ?bool {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    return TerminalClient.of(client).view.removeAttachment(id);
}

fn removePromptAttachments(context: *anyopaque, target: data.AttachmentTarget) ?bool {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    return TerminalClient.of(client).view.removePromptAttachments(target);
}

fn attachmentModalActive(context: *anyopaque) bool {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    return TerminalClient.of(client).view.hasAttachmentModal();
}

fn closeAttachmentModal(context: *anyopaque) bool {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    return TerminalClient.of(client).view.closeAttachmentModal();
}

fn attachmentReservation(context: *anyopaque) ?data.PaneBottomReservation {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    return TerminalClient.of(client).view.attachmentReservation();
}

/// Example: `client.presentation = host_ports.presentation(client);`.
pub fn presentation(client: *client_module.AttachedClient) client_module.HostPresentation {
    return .{
        .context = client,
        .resize_fn = resizePresenter,
        .note_input_fn = noteInput,
        .frame_interval_ns_fn = frameIntervalNs,
        .in_flight_fn = presentationInFlight,
        .delivered_geometry_fn = deliveredGeometry,
    };
}

fn resizePresenter(context: *anyopaque, cols: u16, rows: u16) !void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    try TerminalClient.of(client).presenter.resize(cols, rows);
}

fn noteInput(context: *anyopaque, now_ns: u64) void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    TerminalClient.of(client).presenter.noteInput(now_ns);
}

fn frameIntervalNs(context: *anyopaque) u64 {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    return TerminalClient.of(client).presenter.pacer.interval;
}

fn presentationInFlight(context: *anyopaque) bool {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    return TerminalClient.of(client).presenter.presentation_state.active != null;
}

fn deliveredGeometry(context: *anyopaque) ?client_module.Geometry {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    return TerminalClient.of(client).presenter.presentation_state.delivered_geometry;
}

/// Example: `client.timers = host_ports.timers(client);`.
pub fn timers(client: *client_module.AttachedClient) client_module.HostTimers {
    return .{ .context = client, .arm_fn = armTimer };
}

/// One inbox producer per scheduler; the kind names its completion.
fn armTimer(context: *anyopaque, kind: client_module.TimerKind, scheduler: *client_module.Scheduler) !void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    switch (kind) {
        .input => try TerminalClient.of(client).inbox.start(.input_timeout, .{ client_module.wait, .{ client.io, scheduler } }),
        .binding => try TerminalClient.of(client).inbox.start(.binding_timeout, .{ client_module.wait, .{ client.io, scheduler } }),
        .bar => try TerminalClient.of(client).inbox.start(.bar_tick, .{ client_module.wait, .{ client.io, scheduler } }),
        .notification => try TerminalClient.of(client).inbox.start(.notification_tick, .{ client_module.wait, .{ client.io, scheduler } }),
        .sidebar_animation => try TerminalClient.of(client).inbox.start(.sidebar_animation_tick, .{ client_module.wait, .{ client.io, scheduler } }),
    }
}

/// Example: `client.bar_runner = host_ports.barCommands(client);`.
pub fn barCommands(client: *client_module.AttachedClient) client_module.BarCommandRunner {
    return .{ .context = client, .start_fn = startBarCommand };
}

fn startBarCommand(context: *anyopaque, job: client_module.BarUpdatesJob) !void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    try TerminalClient.of(client).inbox.start(.bar_command, .{ executeBarCommand, .{ client.io, job } });
}

fn executeBarCommand(io: std.Io, job: client_module.BarUpdatesJob) client_module.BarUpdatesCompletion {
    return .{
        .execution_id = job.execution_id,
        .result = client_module.runBarCommand(io, job.command),
    };
}

/// Example: `client.path_completion_runner = host_ports.pathCompletions(client);`.
pub fn pathCompletions(client: *client_module.AttachedClient) client_module.PathCompletionRunner {
    return .{ .context = client, .start_fn = startPathCompletion };
}

fn startPathCompletion(context: *anyopaque, job: client_module.PathCompletionJob) !void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    try TerminalClient.of(client).inbox.start(.path_completion, .{ executePathCompletion, .{ client.io, client.gpa, job } });
}

fn executePathCompletion(io: std.Io, gpa: std.mem.Allocator, job: client_module.PathCompletionJob) data.PathCompletionCompletion {
    return .{
        .execution_id = job.execution_id,
        .result = client_module.runPathCompletion(io, gpa, job),
    };
}

/// Example: `client.plugin_runner = host_ports.pluginWorkers(client);`.
pub fn pluginWorkers(client: *client_module.AttachedClient) client_module.PluginWorkerRunner {
    return .{ .context = client, .start_fn = startPluginWorker };
}

fn startPluginWorker(context: *anyopaque, job: client_module.PluginActionsJob) !void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    try TerminalClient.of(client).inbox.start(.plugin_result, .{ executePluginWorker, .{ client.io, client.gpa, job } });
}

fn executePluginWorker(io: std.Io, gpa: std.mem.Allocator, job: client_module.PluginActionsJob) client_module.PluginActionsCompletion {
    return .{
        .execution_id = job.execution_id,
        .result = client_module.executeWorker(io, gpa, job.request),
    };
}

/// Example: `client.clock = host_ports.clock(client);`.
pub fn clock(client: *client_module.AttachedClient) client_module.HostClock {
    return .{ .context = client, .local_time_fn = localTime };
}

fn localTime(_: *anyopaque) client_module.LocalTime {
    return platform.localTime();
}

/// Example: `client.host_input_source = host_ports.hostInput(client);`.
pub fn hostInput(client: *client_module.AttachedClient) client_module.HostInputSource {
    return .{
        .context = client,
        .resume_read_fn = resumeHostRead,
        .route_prompt_bytes_fn = routePromptBytes,
        .adopt_bindings_fn = adoptBindings,
    };
}

fn resumeHostRead(context: *anyopaque) !void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    try host_inputs.scheduleRead(client);
}

/// Decodes replayed terminal bytes into prompt events. Bytes that do not
/// parse while a paste is open are text; a terminal outcome drops the rest.
fn routePromptBytes(context: *anyopaque, bytes: []const u8) !void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));
    var offset: usize = 0;
    while (offset < bytes.len) {
        const parsed = term.parse(bytes[offset..]) orelse {
            const prompt = client.model.name_prompt.currentConst() orelse return;
            if (prompt.pasting) {
                _ = try client.inputPrompt(
                    .{
                        .paste_text = bytes[offset..],
                    },
                );
            }

            return;
        };
        if (parsed.len == 0) {
            return;
        }

        offset += parsed.len;
        const input: client_module.operations.name_prompts.Input = switch (parsed.event) {
            .key => |key| .{ .key = key },
            .paste_start => .paste_start,
            .paste_end => .paste_end,
            .mouse, .terminal_response, .incomplete => continue,
        };
        switch (try client.inputPrompt(input)) {
            .cancelled, .blocked, .finished, .removed => return,
            .unchanged, .routing_changed, .changed, .completion_requested => {},
        }
    }
}

/// The reload validated the bindings with the same keymap limits, so a
/// failure here is a programming error; the previous router stays in place.
fn adoptBindings(context: *anyopaque, config: client_module.RouterConfig) void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));
    const router = host_inputs.buildRouter(config) catch return;

    TerminalClient.of(client).host_input.replaceRouter(client.io, router);
}

/// Example: `client.transport_driver = host_ports.transport(client);`.
pub fn transport(client: *client_module.AttachedClient) client_module.TransportDriver {
    return .{ .context = client, .start_read_fn = startRuntimeRead, .start_send_fn = startRuntimeSend };
}

fn startRuntimeRead(context: *anyopaque, state: *client_module.RuntimeTransportState) !void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    try TerminalClient.of(client).inbox.start(.server, .{ receiveRuntime, .{ client.io, state } });
}

fn startRuntimeSend(context: *anyopaque, state: *client_module.RuntimeTransportState, payload: []const u8) !void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    try TerminalClient.of(client).inbox.start(.sent, .{ sendRuntime, .{ client.io, state, payload } });
}

fn receiveRuntime(io: std.Io, state: *client_module.RuntimeTransportState) anyerror!*const data.RuntimeMessage {
    return state.read(io);
}

fn sendRuntime(io: std.Io, state: *client_module.RuntimeTransportState, payload: []const u8) anyerror!void {
    core.mark(io, .client_send_start);
    defer core.mark(io, .client_send_done);
    return state.send(io, payload);
}

/// Example: `client.config_watcher = host_ports.configWatcher(client);`.
pub fn configWatcher(client: *client_module.AttachedClient) client_module.ConfigReloadWatcher {
    return .{ .context = client, .start_fn = startConfigWatch };
}

fn startConfigWatch(context: *anyopaque, args: client_module.ConfigWaitArgs) !void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    try TerminalClient.of(client).inbox.start(.config_reload, .{ client_module.config_reload.wait, .{args} });
}
