//! Adapts tab attachment retirement to transport, requests and graphics.

const core = @import("telar-core");
const tabs_application = @import("application/tabs/root.zig");
const pane_focus_reports = @import("pane_focus_reports.zig");
const pane_pastes = @import("pane_pastes.zig");
const request_lifecycle = @import("request_lifecycle.zig");

const Client = @import("client.zig");
const runtime_transport = @import("runtime_transport.zig");
const schema = core.schema;
const tab_attachment_retirement = tabs_application.tab_attachment_retirement;

/// Finishes a captured paste, clears reported focus and then detaches every
/// attached or in-flight pane in protocol order.
///
/// ```zig
/// try detach(client, location);
/// ```
pub fn detach(client: *Client, location: schema.TabLocation) !void {
    var use_case: tab_attachment_retirement.RetireTabAttachmentsHandler = .{
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
pub fn effects(client: *Client) tab_attachment_retirement.Effects {
    return .{
        .context = client,
        .attachment_pending = attachmentPending,
        .detach_pane = detachPane,
        .retire_attachment = retireAttachment,
        .hide_graphics = hideGraphics,
    };
}

fn attachmentPending(context: *anyopaque, pane_id: schema.PaneId) bool {
    const client: *Client = @ptrCast(@alignCast(context));

    return request_lifecycle.hasPane(client, .attachment, pane_id);
}

fn detachPane(context: *anyopaque, pane_id: schema.PaneId) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    try runtime_transport.enqueue(client, .{ .detach_pane = .{ .pane_id = pane_id } });
}

fn retireAttachment(context: *anyopaque, pane_id: schema.PaneId) void {
    const client: *Client = @ptrCast(@alignCast(context));
    _ = request_lifecycle.ignoreAttachment(client, pane_id);
}

fn hideGraphics(context: *anyopaque, pane_id: schema.PaneId) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    try client.graphics_store.setPaneVisible(pane_id, false);
}
