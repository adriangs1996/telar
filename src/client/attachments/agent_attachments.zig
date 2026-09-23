//! Agent attachments: keeps the image markers in an agent's prompt and the
//! attachment shelf in step.
const attachment_prompt = @import("../input/attachment_prompt.zig");
const markers_module = @import("markers.zig");
const data = @import("model");
const core = @import("telar-core");
const pane_input = @import("../panes/pane_input.zig");
const Client = @import("../execution/Client.zig");

/// Deletes the paired child marker and then retires one local preview.
/// Example: `_ = try agent_attachments.dismissAttachment(app, id);`
pub fn dismissAttachment(client: *Client, id: data.AttachmentId) !bool {
    const command = planAttachmentRemoval(client, id) orelse return false;
    try deliverAttachmentRemoval(client, command);
    const shelf = client.attachments orelse return false;
    return shelf.remove(id) orelse false;
}

/// Records a marker deletion only for the visible attachment target and compatible key.
/// Example: `agent_attachments.expectMarkerDeletion(app, pane_id, command);`
pub fn expectMarkerDeletion(client: *Client, pane_id: core.PaneId, command: data.KeyRoutingCommand) void {
    const key = switch (command) {
        .bytes => return,
        .key => |value| value,
    };
    const shelf = client.attachments orelse return;
    const target = shelf.visibleTarget() orelse return;
    if (target.pane_id != pane_id) {
        return;
    }

    const policy = attachmentMarkerPolicy(&client.model, target) orelse return;
    if (!attachment_prompt.editsMarkers(policy, key)) {
        return;
    }

    shelf.expectMarkerDeletion(target);
}

/// Mirrors one successfully delivered Backspace, Delete or Enter into the
/// preview collection owned by that pane.
pub fn observeAttachmentInput(client: *Client, pane_id: core.PaneId, command: data.KeyRoutingCommand) bool {
    expectMarkerDeletion(client, pane_id, command);
    const key = switch (command) {
        .bytes => return false,
        .key => |value| value,
    };
    if (key.phase == .release or key.mods.ctrl or key.mods.alt or key.mods.shift) {
        return false;
    }

    const shelf = client.attachments orelse return false;
    const target = shelf.visibleTarget() orelse
        client.model.focusedAttachmentTarget() orelse return false;
    if (target.pane_id != pane_id) {
        return false;
    }

    switch (key.code) {
        .enter => {
            if (attachmentPromptContinues(client, target)) {
                return false;
            }

            _ = client.model.clipboard.cancel(target);

            return shelf.removePrompt(target) orelse false;
        },
        .backspace, .delete => {
            const deletion: data.AttachmentMarkerDeletion = if (key.code == .backspace) .backward else .forward;
            const id = attachmentMarkerAtCursor(client, deletion);
            if (id == null) {
                if (pendingAttachmentMarkerAtCursor(client, deletion)) {
                    _ = client.model.clipboard.cancel(target);
                }

                return false;
            }

            return shelf.remove(id.?) orelse false;
        },
        else => return false,
    }
}

/// Resolves the marker policy of a target whose provider learns marker
/// identities from committed frames.
fn attachmentMarkerPolicy(model: *data.ClientModel, target: data.AttachmentTarget) ?data.AttachmentMarkerPolicy {
    const markers = model.attachmentMarkers(target) orelse return null;
    const policy = attachment_prompt.markerPolicy(markers);

    return if (policy.learnsIdentity()) policy else null;
}

/// Reconciles learned attachment identities (Claude numbers, Pi paths)
/// after one pane frame.
pub fn reconcileAttachmentFrame(client: *Client, pane_id: core.PaneId) bool {
    const shelf = client.attachments orelse return false;
    const target = shelf.visibleTarget() orelse return false;
    if (target.pane_id != pane_id or attachmentMarkerPolicy(&client.model, target) == null) {
        return false;
    }

    const pane = client.model.panes.findConst(pane_id) orelse return false;

    return shelf.reconcileMarkers(
        target,
        .{
            .buffer = &pane.buffer,
            .cursor = pane.cursor,
        },
    ) orelse false;
}

fn planAttachmentRemoval(client: *Client, id: data.AttachmentId) ?data.RemovalCommand {
    const shelf = client.attachments orelse return null;
    const target = shelf.visibleTarget() orelse return null;
    const model = client.model.tabs.activeSlot() orelse return null;
    const pane = client.model.panes.findInConst(client.model.tabs.location[model].tab_id, target.pane_id) orelse return null;
    const marker = shelf.planMarkerRemoval(
        id,
        .{
            .buffer = &pane.buffer,
            .cursor = pane.cursor,
        },
    ) orelse return null;

    return .{
        .pane_id = target.pane_id,
        .marker = marker,
    };
}

fn deliverAttachmentRemoval(client: *Client, command: data.RemovalCommand) !void {
    var keys: [data.attachment_types.max_removal_keys]data.Key = undefined;
    var len: usize = 0;
    const movement: data.Key.Code = switch (command.marker.direction) {
        .left => .left,
        .right => .right,
    };
    const restoration: data.Key.Code = switch (command.marker.direction) {
        .left => .right,
        .right => .left,
    };
    for (0..command.marker.steps) |_| {
        keys[len] = .{
            .code = movement,
        };
        len += 1;
    }

    for (0..command.marker.deletions) |_| {
        keys[len] = .{
            .code = switch (command.marker.deletion) {
                .backward => .backspace,
                .forward => .delete,
            },
        };
        len += 1;
    }

    for (0..command.marker.steps) |_| {
        keys[len] = .{
            .code = restoration,
        };
        len += 1;
    }

    _ = try pane_input.sendPaneKeys(
        client,
        .{
            .pane = command.pane_id,
        },
        keys[0..len],
    ) orelse
        return error.AttachmentMarkerDeliveryUnavailable;
}

fn attachmentMarkerAtCursor(client: *Client, deletion: data.AttachmentMarkerDeletion) ?data.AttachmentId {
    const shelf = client.attachments orelse return null;
    const target = shelf.visibleTarget() orelse return null;
    const model = client.model.tabs.activeSlot() orelse return null;
    const pane = client.model.panes.findInConst(client.model.tabs.location[model].tab_id, target.pane_id) orelse return null;

    return shelf.idAtMarkerDeletion(
        .{
            .buffer = &pane.buffer,
            .cursor = pane.cursor,
        },
        deletion,
    );
}

fn pendingAttachmentMarkerAtCursor(client: *Client, deletion: data.AttachmentMarkerDeletion) bool {
    const target = client.model.focusedAttachmentTarget() orelse return false;
    const model = client.model.tabs.activeSlot() orelse return false;
    const pane = client.model.panes.findInConst(client.model.tabs.location[model].tab_id, target.pane_id) orelse return false;

    const markers = client.model.attachmentMarkers(target) orelse return false;

    const shelf = client.attachments orelse return false;
    return shelf.pendingMarkerAtDeletion(
        .{
            .buffer = &pane.buffer,
            .cursor = pane.cursor,
        },
        .{
            .deletion = deletion,
            .policy = attachment_prompt.markerPolicy(markers),
        },
    );
}

/// Reports whether the accepted Enter continues the prompt instead of
/// submitting it: the agent's editor treats a trailing backslash as a
/// newline request.
fn attachmentPromptContinues(client: *Client, target: data.AttachmentTarget) bool {
    const markers = client.model.attachmentMarkers(target) orelse return false;
    if (!attachment_prompt.backslashContinuesPrompt(attachment_prompt.markerPolicy(markers))) {
        return false;
    }

    const model = client.model.tabs.activeSlot() orelse return false;
    const pane = client.model.panes.findInConst(client.model.tabs.location[model].tab_id, target.pane_id) orelse return false;

    return markers_module.promptContinuesAtCursor(
        .{
            .buffer = &pane.buffer,
            .cursor = pane.cursor,
        },
    );
}
