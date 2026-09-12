//! Adapts tab attachment retirement to transport, requests and graphics.

const Client = @import("../../AttachedClient.zig");
const TabLocationType = @import("telar-core").TabLocation;
const RetireTabAttachmentsHandlerType = @import("../../application/tabs/RetireTabAttachmentsHandler.zig");
const pane_pastes = @import("../input/pane_pastes.zig");
const pane_focus_reports = @import("../panes/pane_focus_reports.zig");
const TabAttachmentRetirementEffects = @import("../../application/tabs/TabAttachmentRetirementEffects.zig");
const PaneIdType = @import("telar-core").PaneId;
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const runtime_transport = @import("../../entrypoints/runtime_io.zig");

/// Finishes a captured paste, clears reported focus and then detaches every
/// attached or in-flight pane in protocol order.
///
/// ```zig
/// try detach(client, location);
/// ```
pub fn detach(client: *Client, location: TabLocationType) !void {
    var use_case: RetireTabAttachmentsHandlerType = .{
        .model = &client.model,
        .paste_effects = pane_pastes.effects(client),
        .focus_effects = pane_focus_reports.effects(client),
        .effects = effects(client),
    };

    try use_case.execute(location);
}

/// Returns the attachment-retirement ports reused by compound application
/// flows.
///
/// ```zig
/// const attachment_effects = effects(client);
/// ```
pub fn effects(client: *Client) TabAttachmentRetirementEffects {
    return .{
        .context = client,
        .attachment_pending = attachmentPending,
        .detach_pane = detachPane,
        .retire_attachment = retireAttachment,
        .hide_graphics = hideGraphics,
    };
}

fn attachmentPending(context: *anyopaque, pane_id: PaneIdType) bool {
    const client: *Client = @ptrCast(@alignCast(context));

    return request_lifecycle.hasPane(client, .attachment, pane_id);
}

fn detachPane(context: *anyopaque, pane_id: PaneIdType) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    try runtime_transport.enqueue(client, .{ .detach_pane = .{ .pane_id = pane_id } });
}

fn retireAttachment(context: *anyopaque, pane_id: PaneIdType) void {
    const client: *Client = @ptrCast(@alignCast(context));
    _ = request_lifecycle.ignoreAttachment(client, pane_id);
}

fn hideGraphics(context: *anyopaque, pane_id: PaneIdType) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    try client.graphics.setPaneVisible(pane_id, false);
}
