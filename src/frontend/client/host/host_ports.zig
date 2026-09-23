//! Terminal implementations of the client's host service ports. Each port
//! binds one heap-stable client so workers complete through its event loop.

const tab_drag = @import("../input/tab_drag.zig");
const SidebarRendererInput = @import("../../graphics/SidebarRendererInput.zig");
const client_module = @import("telar-client");
const data = @import("model");
const core = @import("telar-core");
const TerminalClient = @import("../TerminalClient.zig");
const platform = @import("../../platform/platform.zig");
const host_inputs = @import("../input/host_inputs.zig");
const history_inspection = @import("../presentation/history_inspection.zig");
const term = @import("../../presentation/screen_support.zig");
const std = @import("std");

/// Example: `client.graphics = host_ports.graphicsRetention(terminal);`.
pub fn graphicsRetention(terminal: *TerminalClient) client_module.GraphicsRetention {
    return .{
        .context = terminal,
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
    const terminal: *TerminalClient = @ptrCast(@alignCast(context));

    return switch (command) {
        .snapshot => |message| terminal.graphics_store.applySnapshot(message),
        .image => |message| terminal.graphics_store.applyImage(message),
        .shared_image => |message| terminal.graphics_store.applySharedImage(message),
        .image_chunk => |message| terminal.graphics_store.applyChunk(message),
        .placement => |message| terminal.graphics_store.applyPlacement(message),
        .delete_image => |message| terminal.graphics_store.deleteImage(message),
        .delete_placement => |message| terminal.graphics_store.deletePlacement(message),
    };
}

fn clearPaneGraphics(context: *anyopaque, pane_id: core.PaneId) void {
    const terminal: *TerminalClient = @ptrCast(@alignCast(context));

    terminal.graphics_store.clearPane(pane_id);
}

fn setPaneGraphicsVisible(context: *anyopaque, pane_id: core.PaneId, visible: bool) !void {
    const terminal: *TerminalClient = @ptrCast(@alignCast(context));

    try terminal.graphics_store.setPaneVisible(pane_id, visible);
}

fn paneGraphicsVisible(context: *anyopaque, pane_id: core.PaneId) bool {
    const terminal: *TerminalClient = @ptrCast(@alignCast(context));

    return terminal.graphics_store.paneVisible(pane_id);
}

fn hasPaneGraphics(context: *anyopaque, pane_id: core.PaneId) bool {
    const terminal: *TerminalClient = @ptrCast(@alignCast(context));

    return terminal.graphics_store.hasPaneGraphics(pane_id);
}

fn graphicsIngressVersion(context: *anyopaque) u64 {
    const terminal: *TerminalClient = @ptrCast(@alignCast(context));

    return terminal.graphics_store.ingressVersion();
}

fn peekGraphicsCredit(context: *anyopaque) ?client_module.GraphicsCredit {
    const terminal: *TerminalClient = @ptrCast(@alignCast(context));

    return terminal.graphics_store.peekCredit();
}

fn consumeGraphicsCredit(context: *anyopaque, credit: client_module.GraphicsCredit) void {
    const terminal: *TerminalClient = @ptrCast(@alignCast(context));

    terminal.graphics_store.consumeCredit(credit);
}

/// Queues deletes for every emitted Kitty placement and marks them dirty.
/// Writes one borrowed payload as OSC 52 and flushes it.
/// Example: `client.chrome = host_ports.chrome(terminal);`.
pub fn chrome(terminal: *TerminalClient) client_module.HostChrome {
    return .{
        .context = terminal,
        .pointer_fn = pointer,
        .inspection_scroll_limit_fn = inspectionScrollLimit,
    };
}

fn inspectionScrollLimit(context: *anyopaque) ?u32 {
    const terminal: *TerminalClient = @ptrCast(@alignCast(context));
    const client = &terminal.app;

    return history_inspection.scrollLimit(&client.model);
}

fn pointer(context: *anyopaque, event: data.Mouse) client_module.ViewInteractionCommand {
    const terminal: *TerminalClient = @ptrCast(@alignCast(context));
    if (tab_drag.press(terminal, event)) |interaction| {
        return interaction;
    }

    const interaction = terminal.view.handleMouse(event);
    if (interaction.intent == .select_tab or interaction.intent == .rename_tab) {
        return .{ .consumed = true };
    }

    return interaction;
}

fn visibleAttachmentTarget(context: *anyopaque) ?data.AttachmentTarget {
    const terminal: *TerminalClient = @ptrCast(@alignCast(context));

    return terminal.view.kittyAttachments().visibleTarget();
}

fn planMarkerRemoval(context: *anyopaque, id: data.AttachmentId, screen: client_module.MarkerScreen) ?data.MarkerRemoval {
    const terminal: *TerminalClient = @ptrCast(@alignCast(context));

    return terminal.view.kittyAttachments().planMarkerRemoval(id, screen);
}

fn idAtMarkerDeletion(context: *anyopaque, screen: client_module.MarkerScreen, deletion: data.AttachmentMarkerDeletion) ?data.AttachmentId {
    const terminal: *TerminalClient = @ptrCast(@alignCast(context));

    return terminal.view.kittyAttachments().idAtMarkerDeletion(screen, deletion);
}

fn pendingMarkerAtDeletion(context: *anyopaque, screen: client_module.MarkerScreen, probe: client_module.DeletionProbe) bool {
    const terminal: *TerminalClient = @ptrCast(@alignCast(context));

    return terminal.view.kittyAttachments().pendingMarkerAtDeletion(screen, probe);
}

fn expectMarkerDeletion(context: *anyopaque, target: data.AttachmentTarget) void {
    const terminal: *TerminalClient = @ptrCast(@alignCast(context));

    terminal.view.kittyAttachments().expectMarkerDeletion(target);
}

/// Example: `client.attachments = host_ports.attachmentShelf(terminal);`.
pub fn attachmentShelf(terminal: *TerminalClient) client_module.AttachmentShelf {
    return .{
        .context = terminal,
        .adopt_fn = adoptAttachment,
        .reconcile_markers_fn = reconcileAttachmentMarkers,
        .sync_target_fn = syncAttachmentTarget,
        .remove_fn = removeAttachment,
        .remove_prompt_fn = removePromptAttachments,
        .modal_active_fn = attachmentModalActive,
        .close_modal_fn = closeAttachmentModal,
        .reservation_fn = attachmentReservation,
        .visible_target_fn = visibleAttachmentTarget,
        .plan_marker_removal_fn = planMarkerRemoval,
        .id_at_marker_deletion_fn = idAtMarkerDeletion,
        .pending_marker_at_deletion_fn = pendingMarkerAtDeletion,
        .expect_marker_deletion_fn = expectMarkerDeletion,
    };
}

fn adoptAttachment(context: *anyopaque, value: *data.Capture) !bool {
    const terminal: *TerminalClient = @ptrCast(@alignCast(context));

    return terminal.view.adoptAttachment(value);
}

fn reconcileAttachmentMarkers(context: *anyopaque, target: data.AttachmentTarget, screen: client_module.MarkerScreen) ?bool {
    const terminal: *TerminalClient = @ptrCast(@alignCast(context));

    return terminal.view.reconcileAttachmentMarkers(target, screen);
}

fn syncAttachmentTarget(context: *anyopaque, target: ?data.AttachmentTarget) bool {
    const terminal: *TerminalClient = @ptrCast(@alignCast(context));

    return terminal.view.syncAttachmentTarget(target);
}

fn removeAttachment(context: *anyopaque, id: data.AttachmentId) ?bool {
    const terminal: *TerminalClient = @ptrCast(@alignCast(context));

    return terminal.view.removeAttachment(id);
}

fn removePromptAttachments(context: *anyopaque, target: data.AttachmentTarget) ?bool {
    const terminal: *TerminalClient = @ptrCast(@alignCast(context));

    return terminal.view.removePromptAttachments(target);
}

fn attachmentModalActive(context: *anyopaque) bool {
    const terminal: *TerminalClient = @ptrCast(@alignCast(context));

    return terminal.view.hasAttachmentModal();
}

fn closeAttachmentModal(context: *anyopaque) bool {
    const terminal: *TerminalClient = @ptrCast(@alignCast(context));

    return terminal.view.closeAttachmentModal();
}

fn attachmentReservation(context: *anyopaque) ?data.PaneBottomReservation {
    const terminal: *TerminalClient = @ptrCast(@alignCast(context));

    return terminal.view.attachmentReservation();
}

/// Example: `client.host_input_source = host_ports.hostInput(terminal);`.
pub fn hostInput(terminal: *TerminalClient) client_module.HostInputSource {
    return .{
        .context = terminal,
        .route_prompt_bytes_fn = routePromptBytes,
    };
}

/// Decodes replayed terminal bytes into prompt events. Bytes that do not
/// parse while a paste is open are text; a terminal outcome drops the rest.
fn routePromptBytes(context: *anyopaque, bytes: []const u8) !void {
    const terminal: *TerminalClient = @ptrCast(@alignCast(context));
    const client = &terminal.app;
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
        const input: client_module.name_prompts.Input = switch (parsed.event) {
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
