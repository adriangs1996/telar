//! Native services for the terminal-only window. Chrome without a visible
//! surface has no effects; unavailable external services fail explicitly.
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
const BarCommandRunnerType = @import("telar-client").BarCommandRunner;
const BarUpdatesJobType = @import("telar-client").BarUpdatesJob;
const PluginWorkerRunnerType = @import("telar-client").PluginWorkerRunner;
const PluginActionsJobType = @import("telar-client").PluginActionsJob;
const HostClockType = @import("telar-client").HostClock;
const LocalTimeType = @import("telar-client").LocalTime;
const HostInputSourceType = @import("telar-client").HostInputSource;
const RouterConfigType = @import("telar-client").RouterConfig;
const TransportDriverType = @import("telar-client").TransportDriver;
const RuntimeTransportStateType = @import("telar-client").RuntimeTransportState;
const SidebarRenderingType = @import("telar-client").SidebarRendering;
const RegionType = @import("telar-client").Region;
const name_prompts = @import("telar-client").controllers.name_prompts;
const ConfigReloadWatcherType = @import("telar-client").ConfigReloadWatcher;
const ConfigWaitArgsType = @import("telar-client").ConfigWaitArgs;
const config_reload = @import("telar-client").config_reload;
const DeliveryType = @import("telar-client").Delivery;
const InputType = @import("telar-client").NotificationInput;
const AgentSoundType = @import("telar-core").AgentSound;
const TargetType = @import("telar-client").LinkTarget;
const CaptureRequestType = @import("telar-client").CaptureRequest;
const CaptureType = @import("telar-client").Capture;
const std = @import("std");
const GuiClient = @import("GuiClient.zig");
const host = GuiClient.of;
const native = @import("native/native.zig");

/// Example: `const port = sound(app);`.
pub fn sound(client: *Client) SoundPortType {
    return .{ .context = client, .play = playSound };
}

/// Example: `const port = notifier(app);`.
pub fn notifier(client: *Client) HostNotifierType {
    return .{ .context = client, .deliver = deliverNotification };
}

/// Example: `const port = links(app);`.
pub fn links(client: *Client) LinkOpenerType {
    return .{ .context = client, .open = openLink };
}

/// Example: `const port = capture(app);`.
pub fn capture(client: *Client) CapturePortType {
    return .{ .context = client, .supported = captureSupported, .start = startCapture };
}

/// Example: `const port = clipboard(app);`.
pub fn clipboard(client: *Client) HostClipboardType {
    return .{ .context = client, .set = setClipboard };
}

/// Example: `const port = graphics(app);`.
pub fn graphics(client: *Client) HostGraphicsType {
    return .{ .context = client, .invalidate_placements = invalidatePlacements };
}

/// Example: `const port = graphicsRetention(app);`.
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

/// Example: `const port = chrome(app);`.
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

/// Example: `const port = attachmentCatalog(app);`.
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

/// Example: `const port = attachmentShelf(app);`.
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

/// Example: `const port = presentation(app);`.
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

/// Example: `const port = timers(app);`.
pub fn timers(client: *Client) HostTimersType {
    return .{ .context = client, .arm_fn = armTimer };
}

/// Example: `const port = barCommands(app);`.
pub fn barCommands(client: *Client) BarCommandRunnerType {
    return .{ .context = client, .start_fn = startBarCommand };
}

/// Example: `const port = pluginWorkers(app);`.
pub fn pluginWorkers(client: *Client) PluginWorkerRunnerType {
    return .{ .context = client, .start_fn = startPluginWorker };
}

/// Example: `const port = clock(app);`.
pub fn clock(client: *Client) HostClockType {
    return .{ .context = client, .local_time_fn = localTime };
}

/// Example: `const port = hostInput(app);`.
pub fn hostInput(client: *Client) HostInputSourceType {
    return .{
        .context = client,
        .resume_read_fn = resumeHostRead,
        .route_prompt_bytes_fn = routePromptBytes,
        .adopt_bindings_fn = adoptBindings,
    };
}

/// Example: `const port = transport(app);`.
pub fn transport(client: *Client) TransportDriverType {
    return .{ .context = client, .start_read_fn = startRuntimeRead, .start_send_fn = startRuntimeSend };
}

/// Example: `const port = configWatcher(app);`.
pub fn configWatcher(client: *Client) ConfigReloadWatcherType {
    return .{ .context = client, .start_fn = startConfigWatch };
}

fn adoptAttachment(_: *anyopaque, _: *CaptureType) !bool {
    return false;
}

fn adoptBindings(_: *anyopaque, _: RouterConfigType) void {}

fn adoptSidebarRenderer(_: *anyopaque, _: SidebarRenderingType) void {}

fn applyGraphics(context: *anyopaque, command: PaneGraphicsCommand) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    return host(client).applyGraphics(command);
}

fn armTimer(_: *anyopaque, _: TimerKindType, _: *SchedulerType) !void {}

fn attachmentModalActive(_: *anyopaque) bool {
    return false;
}

fn attachmentReservation(_: *anyopaque) ?PaneBottomReservationType {
    return null;
}

fn captureSupported(_: *anyopaque) bool {
    return false;
}

fn clearPaneGraphics(context: *anyopaque, pane_id: PaneIdType) void {
    const client: *Client = @ptrCast(@alignCast(context));
    host(client).graphics_store.clearPane(pane_id);
}

fn closeAttachmentModal(_: *anyopaque) bool {
    return false;
}

fn configureSidebar(_: *anyopaque, _: SidebarRendererInputType) !void {}

fn consumeGraphicsCredit(context: *anyopaque, credit: GraphicsCreditType) void {
    const client: *Client = @ptrCast(@alignCast(context));
    host(client).graphics_store.consumeCredit(credit);
}

fn deliverNotification(_: *anyopaque, _: DeliveryType, _: InputType) !void {}

fn deliveredGeometry(context: *anyopaque) ?GeometryType {
    const client: *Client = @ptrCast(@alignCast(context));
    return host(client).lifecycle.delivered_geometry;
}

fn expectMarkerDeletion(_: *anyopaque, _: AttachmentTargetType) void {}

fn frameIntervalNs(context: *anyopaque) u64 {
    _ = context;
    return std.time.ns_per_s / 60;
}

fn graphicsIngressVersion(context: *anyopaque) u64 {
    const client: *Client = @ptrCast(@alignCast(context));
    return host(client).graphics_store.ingressVersion();
}

fn hasPaneGraphics(context: *anyopaque, pane_id: PaneIdType) bool {
    const client: *Client = @ptrCast(@alignCast(context));
    return host(client).graphics_store.hasPaneGraphics(pane_id);
}

fn idAtMarkerDeletion(_: *anyopaque, _: MarkerScreenType, _: MarkerDeletionType) ?AttachmentIdType {
    return null;
}

fn inspectionScrollLimit(_: *anyopaque) ?u32 {
    return null;
}

fn invalidatePlacements(_: *anyopaque) void {}

fn localTime(_: *anyopaque) LocalTimeType {
    var output: [7]u16 = undefined;
    native.telar_gui_local_time(&output);
    return .{ .year = output[0], .month = @intCast(output[1]), .day = @intCast(output[2]), .hour = @intCast(output[3]), .minute = @intCast(output[4]), .second = @intCast(output[5]), .weekday = @intCast(output[6]) };
}

fn noteInput(_: *anyopaque, _: u64) void {}

fn openLink(_: *anyopaque, _: TargetType) !void {
    return error.NativeServiceUnavailable;
}

fn paneGraphicsVisible(context: *anyopaque, pane_id: PaneIdType) bool {
    const client: *Client = @ptrCast(@alignCast(context));
    return host(client).graphics_store.paneVisible(pane_id);
}

fn peekGraphicsCredit(context: *anyopaque) ?GraphicsCreditType {
    const client: *Client = @ptrCast(@alignCast(context));
    return host(client).graphics_store.peekCredit();
}

fn pendingMarkerAtDeletion(_: *anyopaque, _: MarkerScreenType, _: DeletionProbeType) bool {
    return false;
}

fn planMarkerRemoval(_: *anyopaque, _: AttachmentIdType, _: MarkerScreenType) ?MarkerRemovalType {
    return null;
}

fn playSound(_: *anyopaque, _: AgentSoundType) !void {}

fn pointer(context: *anyopaque, event: MouseType) ViewInteractionCommandType {
    _ = context;
    _ = event;
    return .{};
}

fn presentationInFlight(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));
    return host(client).lifecycle.active != null;
}

fn reconcileAttachmentMarkers(_: *anyopaque, _: AttachmentTargetType, _: MarkerScreenType) ?bool {
    return null;
}

fn region(context: *anyopaque) RegionType {
    const client: *Client = @ptrCast(@alignCast(context));
    return host(client).region;
}

fn removeAttachment(_: *anyopaque, _: AttachmentIdType) ?bool {
    return null;
}

fn removePromptAttachments(_: *anyopaque, _: AttachmentTargetType) ?bool {
    return null;
}

fn resizePresenter(_: *anyopaque, _: u16, _: u16) !void {}

fn resizeView(context: *anyopaque, cols: u16, rows: u16) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    host(client).resizeRegion(cols, rows);
}

fn resumeHostRead(context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    try host(client).input.drain(client);
}

fn routePromptBytes(_: *anyopaque, _: []const u8) !void {
    return error.NativeServiceUnavailable;
}

fn setClipboard(context: *anyopaque, bytes: []const u8) !void {
    _ = context;
    if (native.telar_gui_clipboard(bytes.ptr, bytes.len) != 0) {
        std.log.warn("native clipboard update was not applied: clipboard unavailable", .{});
    }
}

fn setIconTheme(_: *anyopaque, _: IconThemeType) void {}

fn setPaneGraphicsVisible(context: *anyopaque, pane_id: PaneIdType, visible: bool) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    try host(client).graphics_store.setPaneVisible(pane_id, visible);
}

fn setSidebarLayout(_: *anyopaque, _: bool, _: u16) void {}

fn setTheme(context: *anyopaque, theme: ColorThemeType) void {
    const client: *Client = @ptrCast(@alignCast(context));
    host(client).theme = theme;
}

fn setWorkspaceListCollapsed(_: *anyopaque, _: bool) void {}

fn sidebarRenderer(context: *anyopaque) SidebarRenderingType {
    _ = context;
    return .cells;
}

fn startBarCommand(_: *anyopaque, _: BarUpdatesJobType) !void {
    return error.NativeServiceUnavailable;
}

fn startCapture(_: *anyopaque, _: CaptureRequestType) !void {
    return error.NativeServiceUnavailable;
}

fn startConfigWatch(_: *anyopaque, _: ConfigWaitArgsType) !void {
    return error.NativeServiceUnavailable;
}

fn startPluginWorker(_: *anyopaque, _: PluginActionsJobType) !void {
    return error.NativeServiceUnavailable;
}

fn startRuntimeRead(context: *anyopaque, state: *RuntimeTransportStateType) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    try host(client).driver.startRead(state);
}

fn startRuntimeSend(context: *anyopaque, state: *RuntimeTransportStateType, payload: []const u8) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    try host(client).driver.startSend(.{ .state = state, .bytes = payload });
}

fn syncAttachmentTarget(_: *anyopaque, _: ?AttachmentTargetType) bool {
    return false;
}

fn visibleAttachmentTarget(_: *anyopaque) ?AttachmentTargetType {
    return null;
}
