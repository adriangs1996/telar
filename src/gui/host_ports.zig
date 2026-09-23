//! Native adapter port assembly. Capabilities own their service implementations.
const client_module = @import("telar-client");
const data = @import("model");
const core = @import("telar-core");
const chrome_module = @import("ports/chrome.zig");
const host_input = @import("ports/host_input.zig");
const worker_ports = @import("ports/workers.zig");
const std = @import("std");
const GuiClient = @import("GuiClient.zig");
const NativeLoop = @import("NativeLoop.zig");
const ConfigurationReload = @import("ConfigurationReload.zig");
const native = @import("native/native.zig");

/// Example: `const port = graphicsRetention(app);`.
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

/// Example: `const port = attachmentCatalog(app);`.
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

/// Example: `const port = attachmentShelf(app);`.
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

/// Example: `const port = presentation(app);`.
pub fn presentation(client: *client_module.AttachedClient) client_module.HostPresentation {
    return .{
        .context = client,
        .resize_fn = resizePresenter,
        .note_input_fn = noteInput,
        .note_pane_input_fn = notePaneInput,
        .frame_interval_ns_fn = frameIntervalNs,
        .in_flight_fn = presentationInFlight,
        .delivered_geometry_fn = deliveredGeometry,
    };
}

/// Binds configuration work to its owned worker and completion handoff.
/// Example: `const port = configWatcher(&loop.configuration);`
pub fn configWatcher(configuration: *ConfigurationReload) client_module.ConfigReloadWatcher {
    return .{
        .context = configuration,
        .start_fn = startConfigWatch,
    };
}

fn adoptAttachment(_: *anyopaque, _: *data.Capture) !bool {
    return false;
}

fn applyGraphics(context: *anyopaque, command: data.PaneGraphicsCommand) !void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));
    return GuiClient.of(client).applyGraphics(command);
}

fn attachmentModalActive(_: *anyopaque) bool {
    return false;
}

fn attachmentReservation(_: *anyopaque) ?data.PaneBottomReservation {
    return null;
}

fn clearPaneGraphics(context: *anyopaque, pane_id: core.PaneId) void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));
    GuiClient.of(client).graphics_store.clearPane(pane_id);
}

fn closeAttachmentModal(_: *anyopaque) bool {
    return false;
}

fn consumeGraphicsCredit(context: *anyopaque, credit: client_module.GraphicsCredit) void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));
    GuiClient.of(client).graphics_store.consumeCredit(credit);
}

fn deliveredGeometry(context: *anyopaque) ?client_module.Geometry {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));
    return GuiClient.of(client).lifecycle.delivered_geometry;
}

fn expectMarkerDeletion(_: *anyopaque, _: data.AttachmentTarget) void {}

fn frameIntervalNs(context: *anyopaque) u64 {
    _ = context;
    return std.time.ns_per_s / 60;
}

fn graphicsIngressVersion(context: *anyopaque) u64 {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));
    return GuiClient.of(client).graphics_store.ingressVersion();
}

fn hasPaneGraphics(context: *anyopaque, pane_id: core.PaneId) bool {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));
    return GuiClient.of(client).graphics_store.hasPaneGraphics(pane_id);
}

fn idAtMarkerDeletion(_: *anyopaque, _: client_module.MarkerScreen, _: data.AttachmentMarkerDeletion) ?data.AttachmentId {
    return null;
}

fn noteInput(_: *anyopaque, _: u64) void {}

fn notePaneInput(context: *anyopaque, pane_id: core.PaneId, now_ns: u64) void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));
    const gui = GuiClient.of(client);
    const tab = client.model.tabs.activeSlot() orelse return;
    const pane = client.model.panes.findInConst(client.model.tabs.location[tab].tab_id, pane_id) orelse return;
    gui.driver.frame_pacer.noteInput(.{
        .pane_id = pane.id,
        .attachment_generation = pane.attachment_generation,
        .frame_id = pane.applied_frame_id,
        .attached = pane.attached,
    }, now_ns);
}

fn paneGraphicsVisible(context: *anyopaque, pane_id: core.PaneId) bool {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));
    return GuiClient.of(client).graphics_store.paneVisible(pane_id);
}

fn peekGraphicsCredit(context: *anyopaque) ?client_module.GraphicsCredit {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));
    return GuiClient.of(client).graphics_store.peekCredit();
}

fn pendingMarkerAtDeletion(_: *anyopaque, _: client_module.MarkerScreen, _: client_module.DeletionProbe) bool {
    return false;
}

fn planMarkerRemoval(_: *anyopaque, _: data.AttachmentId, _: client_module.MarkerScreen) ?data.MarkerRemoval {
    return null;
}

fn presentationInFlight(context: *anyopaque) bool {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));
    return GuiClient.of(client).lifecycle.active != null;
}

fn reconcileAttachmentMarkers(_: *anyopaque, _: data.AttachmentTarget, _: client_module.MarkerScreen) ?bool {
    return null;
}

fn removeAttachment(_: *anyopaque, _: data.AttachmentId) ?bool {
    return null;
}

fn removePromptAttachments(_: *anyopaque, _: data.AttachmentTarget) ?bool {
    return null;
}

fn resizePresenter(_: *anyopaque, _: u16, _: u16) !void {}

fn setPaneGraphicsVisible(context: *anyopaque, pane_id: core.PaneId, visible: bool) !void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));
    try GuiClient.of(client).graphics_store.setPaneVisible(pane_id, visible);
}

fn startConfigWatch(context: *anyopaque, args: client_module.ConfigWaitArgs) !void {
    const configuration: *ConfigurationReload = @ptrCast(@alignCast(context));

    try configuration.schedule(args);
}

fn syncAttachmentTarget(_: *anyopaque, _: ?data.AttachmentTarget) bool {
    return false;
}

fn visibleAttachmentTarget(_: *anyopaque) ?data.AttachmentTarget {
    return null;
}

pub const chrome = chrome_module.port;
pub const hostInput = host_input.port;
pub const workers = worker_ports.jobs;
pub const favicons = worker_ports.favicons;
