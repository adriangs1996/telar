//! Native adapter port assembly. Capabilities own their service implementations.
const Client = @import("telar-client").AttachedClient;
const SoundPortType = @import("telar-client").SoundPort;
const HostNotifierType = @import("telar-client").HostNotifier;
const CapturePortType = @import("telar-client").CapturePort;
const HostClipboardType = @import("telar-client").HostClipboard;
const HostGraphicsType = @import("telar-client").HostGraphics;
const GraphicsRetentionType = @import("telar-client").GraphicsRetention;
const GraphicsCreditType = @import("telar-client").GraphicsCredit;
const PaneGraphicsCommand = @import("telar-client").ApplicationPanesPaneGraphicsCommand;
const PaneIdType = @import("telar-core").PaneId;
const AttachmentCatalogPortType = @import("telar-client").AttachmentCatalogPort;
const AttachmentShelfType = @import("telar-client").AttachmentShelf;
const AttachmentTargetType = @import("telar-client").AttachmentTarget;
const AttachmentIdType = @import("telar-client").AttachmentId;
const MarkerScreenType = @import("telar-client").MarkerScreen;
const MarkerRemovalType = @import("telar-client").MarkerRemoval;
const MarkerDeletionType = @import("telar-client").MarkerDeletion;
const DeletionProbeType = @import("telar-client").DeletionProbe;
const PaneBottomReservationType = @import("telar-client").PaneBottomReservation;
const HostPresentationType = @import("telar-client").HostPresentation;
const GeometryType = @import("telar-client").Geometry;
const HostClockType = @import("telar-client").HostClock;
const LocalTimeType = @import("telar-client").LocalTime;
const TransportDriverType = @import("telar-client").TransportDriver;
const RuntimeTransportStateType = @import("telar-client").RuntimeTransportState;
const name_prompts = @import("telar-client").controllers.name_prompts;
const ConfigReloadWatcherType = @import("telar-client").ConfigReloadWatcher;
const ConfigWaitArgsType = @import("telar-client").ConfigWaitArgs;
const config_reload = @import("telar-client").config_reload;
const DeliveryType = @import("telar-client").Delivery;
const InputType = @import("telar-client").NotificationInput;
const AgentSoundType = @import("telar-core").AgentSound;
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

/// Example: `const port = clock(app);`.
pub fn clock(client: *Client) HostClockType {
    return .{ .context = client, .local_time_fn = localTime };
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

fn applyGraphics(context: *anyopaque, command: PaneGraphicsCommand) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    return host(client).applyGraphics(command);
}

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

fn invalidatePlacements(_: *anyopaque) void {}

fn localTime(_: *anyopaque) LocalTimeType {
    var output: [7]u16 = undefined;
    native.telar_gui_local_time(&output);
    return .{ .year = output[0], .month = @intCast(output[1]), .day = @intCast(output[2]), .hour = @intCast(output[3]), .minute = @intCast(output[4]), .second = @intCast(output[5]), .weekday = @intCast(output[6]) };
}

fn noteInput(_: *anyopaque, _: u64) void {}

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

fn presentationInFlight(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));
    return host(client).lifecycle.active != null;
}

fn reconcileAttachmentMarkers(_: *anyopaque, _: AttachmentTargetType, _: MarkerScreenType) ?bool {
    return null;
}

fn removeAttachment(_: *anyopaque, _: AttachmentIdType) ?bool {
    return null;
}

fn removePromptAttachments(_: *anyopaque, _: AttachmentTargetType) ?bool {
    return null;
}

fn resizePresenter(_: *anyopaque, _: u16, _: u16) !void {}

fn setClipboard(context: *anyopaque, bytes: []const u8) !void {
    _ = context;
    if (native.telar_gui_clipboard(bytes.ptr, bytes.len) != 0) {
        std.log.warn("native clipboard update was not applied: clipboard unavailable", .{});
    }
}

fn setPaneGraphicsVisible(context: *anyopaque, pane_id: PaneIdType, visible: bool) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    try host(client).graphics_store.setPaneVisible(pane_id, visible);
}

fn startCapture(_: *anyopaque, _: CaptureRequestType) !void {
    return error.NativeServiceUnavailable;
}

fn startConfigWatch(context: *anyopaque, args: ConfigWaitArgsType) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    try host(client).driver.configuration.schedule(args);
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

pub const chrome = @import("ports/chrome.zig").port;
pub const hostInput = @import("ports/host_input.zig").port;
pub const timers = @import("ports/workers.zig").timers;
pub const barCommands = @import("ports/workers.zig").bars;
pub const pluginWorkers = @import("ports/workers.zig").plugins;
pub const pathCompletions = @import("ports/workers.zig").pathCompletions;
pub const favicons = @import("ports/workers.zig").favicons;
pub const links = @import("ports/services.zig").links;
