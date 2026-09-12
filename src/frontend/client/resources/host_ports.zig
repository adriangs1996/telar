//! Terminal implementations of the client's host service ports. Each port
//! binds one heap-stable client so workers complete through its event loop.

const TerminalClient = @import("../TerminalClient.zig");
const host = TerminalClient.of;
const Client = @import("telar-client").AttachedClient;
const SoundPortType = @import("telar-client").SoundPort;
const HostNotifierType = @import("telar-client").HostNotifier;
const LinkOpenerType = @import("telar-client").LinkOpener;
const CapturePortType = @import("telar-client").CapturePort;
const HostClipboardType = @import("telar-client").HostClipboard;
const HostGraphicsType = @import("telar-client").HostGraphics;
const GraphicsRetentionType = @import("telar-client").GraphicsRetention;
const GraphicsCreditType = @import("telar-client").GraphicsCredit;
const PaneGraphicsCommand = @import("telar-client").ApplicationPanesPaneGraphicsCommand;
const PaneIdType = @import("telar-core").PaneId;
const HostChromeType = @import("telar-client").HostChrome;
const AttachmentCatalogPortType = @import("telar-client").AttachmentCatalogPort;
const AttachmentShelfType = @import("telar-client").AttachmentShelf;
const ColorThemeType = @import("telar-client").ColorTheme;
const IconThemeType = @import("telar-client").Theme;
const SidebarRendererInputType = @import("telar-client").SidebarRendererInput;
const MouseType = @import("telar-client").Mouse;
const ViewInteractionCommandType = @import("telar-client").ViewInteractionCommand;
const AttachmentTargetType = @import("telar-client").AttachmentTarget;
const AttachmentIdType = @import("telar-client").AttachmentId;
const MarkerScreenType = @import("telar-client").MarkerScreen;
const MarkerRemovalType = @import("telar-client").MarkerRemoval;
const MarkerDeletionType = @import("telar-client").MarkerDeletion;
const DeletionProbeType = @import("telar-client").DeletionProbe;
const PaneBottomReservationType = @import("telar-client").PaneBottomReservation;
const HostPresentationType = @import("telar-client").HostPresentation;
const GeometryType = @import("telar-client").Geometry;
const HostTimersType = @import("telar-client").HostTimers;
const TimerKindType = @import("telar-client").TimerKind;
const SchedulerType = @import("telar-client").Scheduler;
const wait_module = @import("telar-client").wait;
const BarCommandRunnerType = @import("telar-client").BarCommandRunner;
const BarUpdatesJobType = @import("telar-client").BarUpdatesJob;
const BarUpdatesCompletionType = @import("telar-client").BarUpdatesCompletion;
const runBarCommand_module = @import("telar-client").runBarCommand;
const PluginWorkerRunnerType = @import("telar-client").PluginWorkerRunner;
const PluginActionsJobType = @import("telar-client").PluginActionsJob;
const PluginActionsCompletionType = @import("telar-client").PluginActionsCompletion;
const executeWorker_module = @import("telar-client").executeWorker;
const HostClockType = @import("telar-client").HostClock;
const LocalTimeType = @import("telar-client").LocalTime;
const HostInputSourceType = @import("telar-client").HostInputSource;
const RouterConfigType = @import("telar-client").RouterConfig;
const TransportDriverType = @import("telar-client").TransportDriver;
const RuntimeTransportStateType = @import("telar-client").RuntimeTransportState;
const SidebarRenderingType = @import("telar-client").SidebarRendering;
const RegionType = @import("telar-client").Region;
const platform = @import("../../platform/platform.zig");
const host_inputs = @import("../controllers/input/host_inputs.zig");
const name_prompts = @import("telar-client").controllers.name_prompts;
const history_inspection = @import("../presentation/history_inspection.zig");
const mark_module = @import("telar-core").mark;
const ConfigReloadWatcherType = @import("telar-client").ConfigReloadWatcher;
const ConfigWaitArgsType = @import("telar-client").ConfigWaitArgs;
const config_reload = @import("telar-client").config_reload;
const kitty_delivery = @import("../../graphics/kitty_delivery.zig");
const DeliveryType = @import("telar-client").Delivery;
const InputType = @import("telar-client").NotificationInput;
const AgentSoundType = @import("telar-core").AgentSound;
const TargetType = @import("telar-client").LinkTarget;
const CaptureRequestType = @import("telar-client").CaptureRequest;
const CaptureType = @import("telar-client").Capture;
const Completion = @import("telar-client").controllers.ClipboardImageCompletion;
const sound_worker = @import("../../sound/worker.zig");
const notification_host = @import("../../notifications/host.zig");
const PayloadType = @import("../../notifications/Payload.zig");
const link_host = @import("../../links/host.zig");
const capture_module = @import("../../attachments/capture.zig");
const term = @import("../../presentation/screen_support.zig");
const std = @import("std");

/// Example: `client.sound_port = host_ports.sound(client);`.
pub fn sound(client: *Client) SoundPortType {
    return .{ .context = client, .play = playSound };
}

/// Example: `client.notifier = host_ports.notifier(client);`.
pub fn notifier(client: *Client) HostNotifierType {
    return .{ .context = client, .deliver = deliverNotification };
}

/// Example: `client.link_opener = host_ports.links(client);`.
pub fn links(client: *Client) LinkOpenerType {
    return .{ .context = client, .open = openLink };
}

/// Example: `client.capture_port = host_ports.capture(client);`.
pub fn capture(client: *Client) CapturePortType {
    return .{ .context = client, .supported = captureSupported, .start = startCapture };
}

/// Example: `client.host_clipboard = host_ports.clipboard(client);`.
pub fn clipboard(client: *Client) HostClipboardType {
    return .{ .context = client, .set = setClipboard };
}

/// Example: `client.host_graphics = host_ports.graphics(client);`.
pub fn graphics(client: *Client) HostGraphicsType {
    return .{ .context = client, .invalidate_placements = invalidatePlacements };
}

/// Example: `client.graphics = host_ports.graphicsRetention(client);`.
pub fn graphicsRetention(client: *Client) GraphicsRetentionType {
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

fn applyGraphics(context: *anyopaque, command: PaneGraphicsCommand) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    return switch (command) {
        .snapshot => |message| host(client).graphics_store.applySnapshot(message),
        .image => |message| host(client).graphics_store.applyImage(message),
        .shared_image => |message| host(client).graphics_store.applySharedImage(message),
        .image_chunk => |message| host(client).graphics_store.applyChunk(message),
        .placement => |message| host(client).graphics_store.applyPlacement(message),
        .delete_image => |message| host(client).graphics_store.deleteImage(message),
        .delete_placement => |message| host(client).graphics_store.deletePlacement(message),
    };
}

fn clearPaneGraphics(context: *anyopaque, pane_id: PaneIdType) void {
    const client: *Client = @ptrCast(@alignCast(context));

    host(client).graphics_store.clearPane(pane_id);
}

fn setPaneGraphicsVisible(context: *anyopaque, pane_id: PaneIdType, visible: bool) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try host(client).graphics_store.setPaneVisible(pane_id, visible);
}

fn paneGraphicsVisible(context: *anyopaque, pane_id: PaneIdType) bool {
    const client: *Client = @ptrCast(@alignCast(context));

    return host(client).graphics_store.paneVisible(pane_id);
}

fn hasPaneGraphics(context: *anyopaque, pane_id: PaneIdType) bool {
    const client: *Client = @ptrCast(@alignCast(context));

    return host(client).graphics_store.hasPaneGraphics(pane_id);
}

fn graphicsIngressVersion(context: *anyopaque) u64 {
    const client: *Client = @ptrCast(@alignCast(context));

    return host(client).graphics_store.ingressVersion();
}

fn peekGraphicsCredit(context: *anyopaque) ?GraphicsCreditType {
    const client: *Client = @ptrCast(@alignCast(context));

    return host(client).graphics_store.peekCredit();
}

fn consumeGraphicsCredit(context: *anyopaque, credit: GraphicsCreditType) void {
    const client: *Client = @ptrCast(@alignCast(context));

    host(client).graphics_store.consumeCredit(credit);
}

/// Queues deletes for every emitted Kitty placement and marks them dirty.
fn invalidatePlacements(context: *anyopaque) void {
    const client: *Client = @ptrCast(@alignCast(context));

    kitty_delivery.invalidatePlacements(&host(client).graphics_store);
}

fn playSound(context: *anyopaque, kind: AgentSoundType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try host(client).select.concurrent(.sound_played, sound_worker.play, .{ client.io, kind });
}

/// `terminal` adds OSC 9 for the outer terminal and `system` posts through
/// the operating system on a worker whose scheduling failure is not fatal.
fn deliverNotification(context: *anyopaque, channel: DeliveryType, input: InputType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    switch (channel) {
        .telar => {},
        .terminal => {
            const payload = PayloadType.init(input.title, input.message);
            try term.writeHostNotification(host(client).writer, payload.titleSlice(), payload.messageSlice());
            try host(client).writer.flush();
        },
        .system => {
            const payload = PayloadType.init(input.title, input.message);
            host(client).select.concurrent(.notified, notification_host.notify, .{ client.io, payload }) catch {};
        },
    }
}

fn openLink(context: *anyopaque, target: TargetType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try host(client).select.concurrent(.link_opened, link_host.open, .{ client.io, target });
}

fn captureSupported(_: *anyopaque) bool {
    return capture_module.platformSupported();
}

fn startCapture(context: *anyopaque, request: CaptureRequestType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try host(client).select.concurrent(.clipboard_image, executeCapture, .{
        client.gpa,
        request,
        &client.clipboard_capture_resources.orphan,
    });
}

fn executeCapture(gpa: std.mem.Allocator, request: CaptureRequestType, orphan: *?*CaptureType) Completion {
    return .{
        .execution_id = @enumFromInt(request.sequence),
        .result = capture_module.captureClipboard(gpa, request, orphan),
    };
}

/// Writes one borrowed payload as OSC 52 and flushes it.
fn setClipboard(context: *anyopaque, bytes: []const u8) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try term.writeClipboard(host(client).writer, bytes);
    try host(client).writer.flush();
}

/// Example: `client.chrome = host_ports.chrome(client);`.
pub fn chrome(client: *Client) HostChromeType {
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
    const client: *Client = @ptrCast(@alignCast(context));

    return history_inspection.scrollLimit(&client.model);
}

fn sidebarRenderer(context: *anyopaque) SidebarRenderingType {
    const client: *Client = @ptrCast(@alignCast(context));

    return host(client).sidebar_rendering;
}

fn adoptSidebarRenderer(context: *anyopaque, value: SidebarRenderingType) void {
    const client: *Client = @ptrCast(@alignCast(context));

    host(client).sidebar_rendering = value;
}

fn region(context: *anyopaque) RegionType {
    const client: *Client = @ptrCast(@alignCast(context));

    return host(client).view.geometry();
}

fn setTheme(context: *anyopaque, theme: ColorThemeType) void {
    const client: *Client = @ptrCast(@alignCast(context));

    host(client).view.setTheme(theme);
}

fn setIconTheme(context: *anyopaque, theme: IconThemeType) void {
    const client: *Client = @ptrCast(@alignCast(context));

    host(client).view.setIconTheme(theme);
}

/// The requested renderer is the adapter's own configuration.
fn configureSidebar(context: *anyopaque, input: SidebarRendererInputType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try host(client).view.configureSidebar(host(client).sidebar_rendering, input);
}

fn resizeView(context: *anyopaque, cols: u16, rows: u16) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try host(client).view.resize(cols, rows);
}

fn setSidebarLayout(context: *anyopaque, visible: bool, width: u16) void {
    const client: *Client = @ptrCast(@alignCast(context));

    host(client).view.setSidebarLayout(visible, width);
}

fn setWorkspaceListCollapsed(context: *anyopaque, collapsed: bool) void {
    const client: *Client = @ptrCast(@alignCast(context));

    host(client).view.setWorkspaceListCollapsed(collapsed);
}

fn pointer(context: *anyopaque, event: MouseType) ViewInteractionCommandType {
    const client: *Client = @ptrCast(@alignCast(context));

    return host(client).view.handleMouse(event);
}

/// Example: `client.attachment_catalog = host_ports.attachmentCatalog(client);`.
pub fn attachmentCatalog(client: *Client) AttachmentCatalogPortType {
    return .{
        .context = client,
        .visible_target_fn = visibleAttachmentTarget,
        .plan_marker_removal_fn = planMarkerRemoval,
        .id_at_marker_deletion_fn = idAtMarkerDeletion,
        .pending_marker_at_deletion_fn = pendingMarkerAtDeletion,
        .expect_marker_deletion_fn = expectMarkerDeletion,
    };
}

fn visibleAttachmentTarget(context: *anyopaque) ?AttachmentTargetType {
    const client: *Client = @ptrCast(@alignCast(context));

    return host(client).view.kittyAttachments().visibleTarget();
}

fn planMarkerRemoval(context: *anyopaque, id: AttachmentIdType, screen: MarkerScreenType) ?MarkerRemovalType {
    const client: *Client = @ptrCast(@alignCast(context));

    return host(client).view.kittyAttachments().planMarkerRemoval(id, screen);
}

fn idAtMarkerDeletion(context: *anyopaque, screen: MarkerScreenType, deletion: MarkerDeletionType) ?AttachmentIdType {
    const client: *Client = @ptrCast(@alignCast(context));

    return host(client).view.kittyAttachments().idAtMarkerDeletion(screen, deletion);
}

fn pendingMarkerAtDeletion(context: *anyopaque, screen: MarkerScreenType, probe: DeletionProbeType) bool {
    const client: *Client = @ptrCast(@alignCast(context));

    return host(client).view.kittyAttachments().pendingMarkerAtDeletion(screen, probe);
}

fn expectMarkerDeletion(context: *anyopaque, target: AttachmentTargetType) void {
    const client: *Client = @ptrCast(@alignCast(context));

    host(client).view.kittyAttachments().expectMarkerDeletion(target);
}

/// Example: `client.attachment_shelf = host_ports.attachmentShelf(client);`.
pub fn attachmentShelf(client: *Client) AttachmentShelfType {
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

fn adoptAttachment(context: *anyopaque, value: *CaptureType) !bool {
    const client: *Client = @ptrCast(@alignCast(context));

    return host(client).view.adoptAttachment(value);
}

fn reconcileAttachmentMarkers(context: *anyopaque, target: AttachmentTargetType, screen: MarkerScreenType) ?bool {
    const client: *Client = @ptrCast(@alignCast(context));

    return host(client).view.reconcileAttachmentMarkers(target, screen);
}

fn syncAttachmentTarget(context: *anyopaque, target: ?AttachmentTargetType) bool {
    const client: *Client = @ptrCast(@alignCast(context));

    return host(client).view.syncAttachmentTarget(target);
}

fn removeAttachment(context: *anyopaque, id: AttachmentIdType) ?bool {
    const client: *Client = @ptrCast(@alignCast(context));

    return host(client).view.removeAttachment(id);
}

fn removePromptAttachments(context: *anyopaque, target: AttachmentTargetType) ?bool {
    const client: *Client = @ptrCast(@alignCast(context));

    return host(client).view.removePromptAttachments(target);
}

fn attachmentModalActive(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));

    return host(client).view.hasAttachmentModal();
}

fn closeAttachmentModal(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));

    return host(client).view.closeAttachmentModal();
}

fn attachmentReservation(context: *anyopaque) ?PaneBottomReservationType {
    const client: *Client = @ptrCast(@alignCast(context));

    return host(client).view.attachmentReservation();
}

/// Example: `client.presentation = host_ports.presentation(client);`.
pub fn presentation(client: *Client) HostPresentationType {
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
    const client: *Client = @ptrCast(@alignCast(context));

    try host(client).presenter.resize(cols, rows);
}

fn noteInput(context: *anyopaque, now_ns: u64) void {
    const client: *Client = @ptrCast(@alignCast(context));

    host(client).presenter.noteInput(now_ns);
}

fn frameIntervalNs(context: *anyopaque) u64 {
    const client: *Client = @ptrCast(@alignCast(context));

    return host(client).presenter.pacer.interval;
}

fn presentationInFlight(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));

    return host(client).presenter.presentation_state.active != null;
}

fn deliveredGeometry(context: *anyopaque) ?GeometryType {
    const client: *Client = @ptrCast(@alignCast(context));

    return host(client).presenter.presentation_state.delivered_geometry;
}

/// Example: `client.timers = host_ports.timers(client);`.
pub fn timers(client: *Client) HostTimersType {
    return .{ .context = client, .arm_fn = armTimer };
}

/// One select task per scheduler; the kind names the completion it delivers.
fn armTimer(context: *anyopaque, kind: TimerKindType, scheduler: *SchedulerType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    switch (kind) {
        .input => try host(client).select.concurrent(.input_timeout, wait_module, .{ client.io, scheduler }),
        .binding => try host(client).select.concurrent(.binding_timeout, wait_module, .{ client.io, scheduler }),
        .bar => try host(client).select.concurrent(.bar_tick, wait_module, .{ client.io, scheduler }),
        .notification => try host(client).select.concurrent(.notification_tick, wait_module, .{ client.io, scheduler }),
        .sidebar_animation => try host(client).select.concurrent(.sidebar_animation_tick, wait_module, .{ client.io, scheduler }),
    }
}

/// Example: `client.bar_runner = host_ports.barCommands(client);`.
pub fn barCommands(client: *Client) BarCommandRunnerType {
    return .{ .context = client, .start_fn = startBarCommand };
}

fn startBarCommand(context: *anyopaque, job: BarUpdatesJobType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try host(client).select.concurrent(.bar_command, executeBarCommand, .{ client.io, job });
}

fn executeBarCommand(io: std.Io, job: BarUpdatesJobType) BarUpdatesCompletionType {
    return .{
        .execution_id = job.execution_id,
        .result = runBarCommand_module(io, job.command),
    };
}

/// Example: `client.plugin_runner = host_ports.pluginWorkers(client);`.
pub fn pluginWorkers(client: *Client) PluginWorkerRunnerType {
    return .{ .context = client, .start_fn = startPluginWorker };
}

fn startPluginWorker(context: *anyopaque, job: PluginActionsJobType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try host(client).select.concurrent(.plugin_result, executePluginWorker, .{ client.io, client.gpa, job });
}

fn executePluginWorker(io: std.Io, gpa: std.mem.Allocator, job: PluginActionsJobType) PluginActionsCompletionType {
    return .{
        .execution_id = job.execution_id,
        .result = executeWorker_module(io, gpa, job.request),
    };
}

/// Example: `client.clock = host_ports.clock(client);`.
pub fn clock(client: *Client) HostClockType {
    return .{ .context = client, .local_time_fn = localTime };
}

fn localTime(_: *anyopaque) LocalTimeType {
    return platform.localTime();
}

/// Example: `client.host_input_source = host_ports.hostInput(client);`.
pub fn hostInput(client: *Client) HostInputSourceType {
    return .{
        .context = client,
        .resume_read_fn = resumeHostRead,
        .route_prompt_bytes_fn = routePromptBytes,
        .adopt_bindings_fn = adoptBindings,
    };
}

fn resumeHostRead(context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try host_inputs.scheduleRead(client);
}

/// Decodes replayed terminal bytes into prompt events. Bytes that do not
/// parse while a paste is open are text; a terminal outcome drops the rest.
fn routePromptBytes(context: *anyopaque, bytes: []const u8) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    var offset: usize = 0;
    while (offset < bytes.len) {
        const parsed = term.parse(bytes[offset..]) orelse {
            const prompt = client.model.name_prompt.currentConst() orelse return;
            if (prompt.pasting) {
                _ = try name_prompts.handleInput(client, .{ .paste_text = bytes[offset..] });
            }

            return;
        };
        if (parsed.len == 0) {
            return;
        }

        offset += parsed.len;
        const input: name_prompts.Input = switch (parsed.event) {
            .key => |key| .{ .key = key },
            .paste_start => .paste_start,
            .paste_end => .paste_end,
            .mouse, .terminal_response, .incomplete => continue,
        };
        switch (try name_prompts.handleInput(client, input)) {
            .cancelled, .blocked, .finished, .removed => return,
            .unchanged, .routing_changed, .changed => {},
        }
    }
}

/// The reload validated the bindings with the same keymap limits, so a
/// failure here is a programming error; the previous router stays in place.
fn adoptBindings(context: *anyopaque, config: RouterConfigType) void {
    const client: *Client = @ptrCast(@alignCast(context));
    const router = host_inputs.buildRouter(config) catch return;

    host(client).host_input.replaceRouter(client.io, router);
}

/// Example: `client.transport_driver = host_ports.transport(client);`.
pub fn transport(client: *Client) TransportDriverType {
    return .{ .context = client, .start_read_fn = startRuntimeRead, .start_send_fn = startRuntimeSend };
}

fn startRuntimeRead(context: *anyopaque, state: *RuntimeTransportStateType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try host(client).select.concurrent(.server, receiveRuntime, .{ client.io, state });
}

fn startRuntimeSend(context: *anyopaque, state: *RuntimeTransportStateType, payload: []const u8) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try host(client).select.concurrent(.sent, sendRuntime, .{ client.io, state, payload });
}

fn receiveRuntime(io: std.Io, state: *RuntimeTransportStateType) anyerror![]u8 {
    const bytes = try state.read(io);
    mark_module(io, .client_read);
    return bytes;
}

fn sendRuntime(io: std.Io, state: *RuntimeTransportStateType, payload: []const u8) anyerror!void {
    mark_module(io, .client_send_start);
    defer mark_module(io, .client_send_done);
    return state.send(io, payload);
}

/// Example: `client.config_watcher = host_ports.configWatcher(client);`.
pub fn configWatcher(client: *Client) ConfigReloadWatcherType {
    return .{ .context = client, .start_fn = startConfigWatch };
}

fn startConfigWatch(context: *anyopaque, args: ConfigWaitArgsType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try host(client).select.concurrent(.config_reload, config_reload.wait, .{args});
}
