//! Agent attachments: keeps the image markers in an agent's prompt and the
//! attachment shelf in step.
const keyinput = @import("keyinput");
const attachment_prompt = @import("../input/attachment_prompt.zig");
const markers_module = @import("markers.zig");
const data = @import("model");
const core = @import("telar-core");
const pane_input = @import("../panes/pane_input.zig");
const limit_reached = @import("../notifications/limit_reached.zig");
const Client = @import("../execution/Client.zig");
const MarkerRemovalPlan = @import("MarkerRemovalPlan.zig").MarkerRemovalPlan;

/// Deletes the paired child marker and then retires one local preview. A
/// removal that stops at a limit (navigation steps, a path's cells, keys in
/// one transaction) sends nothing, keeps the preview and reports the limit.
/// Example: `_ = try agent_attachments.dismissAttachment(app, id);`
pub fn dismissAttachment(client: *Client, id: data.AttachmentId) !bool {
    const command = planAttachmentRemoval(client, id) orelse return false;
    const marker = switch (command.plan) {
        .planned => |removal| removal,
        .unreachable_marker => return false,
        .limited => |reach| {
            limit_reached.report(client, reach);
            return false;
        },
    };

    try deliverAttachmentRemoval(
        client,
        .{
            .pane_id = command.pane_id,
            .marker = marker,
        },
    );

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
        data.pane_attachment.focusedTarget(&client.model) orelse return false;
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
    const markers = data.pane_attachment.markersFor(model, target) orelse return null;
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

fn planAttachmentRemoval(client: *Client, id: data.AttachmentId) ?PlannedRemoval {
    const shelf = client.attachments orelse return null;
    const target = shelf.visibleTarget() orelse return null;
    const model = client.model.tabs.activeSlot() orelse return null;
    const pane = client.model.panes.findInConst(client.model.tabs.location[model].tab_id, target.pane_id) orelse return null;
    const plan = shelf.planMarkerRemoval(
        id,
        .{
            .buffer = &pane.buffer,
            .cursor = pane.cursor,
        },
    );

    return .{
        .pane_id = target.pane_id,
        .plan = plan,
    };
}

/// The pane whose prompt holds the marker and the plan that removes it.
const PlannedRemoval = struct {
    pane_id: core.PaneId,
    plan: MarkerRemovalPlan,
};

fn deliverAttachmentRemoval(client: *Client, command: data.RemovalCommand) !void {
    var keys: [data.attachment_types.max_removal_keys]keyinput.Key = undefined;
    var len: usize = 0;
    const movement: keyinput.Key.Code = switch (command.marker.direction) {
        .left => .left,
        .right => .right,
    };
    const restoration: keyinput.Key.Code = switch (command.marker.direction) {
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
    const target = data.pane_attachment.focusedTarget(&client.model) orelse return false;
    const model = client.model.tabs.activeSlot() orelse return false;
    const pane = client.model.panes.findInConst(client.model.tabs.location[model].tab_id, target.pane_id) orelse return false;

    const markers = data.pane_attachment.markersFor(&client.model, target) orelse return false;

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
    const markers = data.pane_attachment.markersFor(&client.model, target) orelse return false;
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
