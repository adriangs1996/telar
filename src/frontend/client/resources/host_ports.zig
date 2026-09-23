//! Terminal implementations of the client's host service ports. Each port
//! binds one heap-stable client so workers complete through its event loop.

const tab_drag = @import("../controllers/input/tab_drag.zig");
const SidebarRendererInput = @import("../../graphics/SidebarRendererInput.zig");
const client_module = @import("telar-client");
const data = @import("model");
const core = @import("telar-core");
const TerminalClient = @import("../TerminalClient.zig");
const platform = @import("../../platform/platform.zig");
const host_inputs = @import("../controllers/input/host_inputs.zig");
const history_inspection = @import("../presentation/history_inspection.zig");
const term = @import("../../presentation/screen_support.zig");
const std = @import("std");

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
/// Writes one borrowed payload as OSC 52 and flushes it.
/// Example: `client.chrome = host_ports.chrome(client);`.
pub fn chrome(client: *client_module.AttachedClient) client_module.HostChrome {
    return .{
        .context = client,
        .pointer_fn = pointer,
        .inspection_scroll_limit_fn = inspectionScrollLimit,
    };
}

fn inspectionScrollLimit(context: *anyopaque) ?u32 {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    return history_inspection.scrollLimit(&client.model);
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

fn adoptAttachment(context: *anyopaque, value: *data.Capture) !bool {
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

/// Example: `client.host_input_source = host_ports.hostInput(client);`.
pub fn hostInput(client: *client_module.AttachedClient) client_module.HostInputSource {
    return .{
        .context = client,
        .route_prompt_bytes_fn = routePromptBytes,
    };
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
/// Example: `client.workers = host_ports.workers(client);`.
pub fn workers(client: *client_module.AttachedClient) client_module.Workers {
    return .{ .context = client, .start_fn = startJob };
}

fn startJob(context: *anyopaque, job: client_module.Job) !void {
    const client: *client_module.AttachedClient = @ptrCast(@alignCast(context));

    try TerminalClient.of(client).inbox.start(.client, .{ client_module.job_runner.run, .{ client.io, client.gpa, job } });
}
